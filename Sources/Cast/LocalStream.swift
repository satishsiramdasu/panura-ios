import AVFoundation
import AudioToolbox
import Foundation

/// A video on this phone, served to a Chromecast as HLS and prepared as the
/// television asks for it.
///
/// The alternative was converting the whole film first: a two-gigabyte file
/// meant minutes of waiting before the first frame. Here the file is cut into
/// segments of about six seconds at its own keyframes, and each is built when
/// the TV fetches it — the picture copied as it is, the chosen audio track
/// copied or encoded to stereo AAC — so playback starts at once and a seek is
/// just a request for a different segment.
///
/// **H.264 only, for now.** A picture that has to be re-encoded (HEVC, Dolby
/// Vision, HDR) still goes through `CastTranscoder`'s whole-file conversion.
///
/// **Transport stream, not fragmented MP4.** The receiver forces TS hints for
/// every HLS load (`receiver.html`, shared with live Android senders), and TS
/// is what the oldest Chromecasts are already proven to play — see
/// `CastRemux`.
///
/// Timestamps are the file's own, offset by two seconds so a B-frame's decode
/// time is never negative. A segment rebuilt after a seek therefore carries
/// exactly the stamps the first build would have, and the receiver's timeline
/// never jumps.
final class LocalStream: @unchecked Sendable {
    enum Failure: Error { case unsupported, unreadable }

    static let targetSeconds = 6.0
    private static let offset: Int64 = 180_000
    private static let videoPID = 0x0100
    private static let audioPID = 0x0101
    private static let pmtPID = 0x1000

    let duration: Double
    /// Segment starts, each on a keyframe, with the end of the film appended.
    private let bounds: [CMTime]
    private let asset: AVURLAsset
    private let video: AVAssetTrack
    private let audio: AVAssetTrack?
    /// Set when the chosen track is already AAC-LC in stereo or mono and can
    /// be copied: what an ADTS header needs to say about it.
    private let copiedAudio: (sampleRate: Double, channels: Int)?
    private let parameterSets: [[UInt8]]
    private let nalLength: Int

    private let lock = NSCondition()
    private var ready: [Int: Data] = [:]
    /// The segment the producer is building, or nil when none is running.
    private var producing: Int?
    private var requested = 0
    private var generation = 0
    private var closed = false

    private init(
        asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack?,
        copiedAudio: (sampleRate: Double, channels: Int)?,
        parameterSets: [[UInt8]], nalLength: Int, bounds: [CMTime], duration: Double
    ) {
        self.asset = asset
        self.video = video
        self.audio = audio
        self.copiedAudio = copiedAudio
        self.parameterSets = parameterSets
        self.nalLength = nalLength
        self.bounds = bounds
        self.duration = duration
    }

    /// Whether `url` can be streamed this way: an H.264 picture.
    static func canStream(_ url: URL) async -> Bool {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let description = try? await track.load(.formatDescriptions).first
        else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        return codec == kCMVideoCodecType_H264 || codec == fourCC("avc3")
    }

    /// Reads what the stream needs up front: the parameter sets, the audio
    /// track's shape, and every keyframe — the one pass over the file, which
    /// reads it without decoding a frame.
    static func open(_ url: URL, audioTrack index: Int?) async throws -> LocalStream {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let description = try await video.load(.formatDescriptions).first
        else { throw Failure.unreadable }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        guard codec == kCMVideoCodecType_H264 || codec == fourCC("avc3") else { throw Failure.unsupported }

        var sets: [[UInt8]] = []
        var count = 0
        var header: Int32 = 4
        _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header
        )
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer {
                sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
            }
        }

        let sounds = try await asset.loadTracks(withMediaType: .audio)
        let audio = index.flatMap { sounds.indices.contains($0) ? sounds[$0] : nil }
        var copied: (sampleRate: Double, channels: Int)?
        if let audio, let format = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC,
           asbd.mFormatFlags == 0 || asbd.mFormatFlags == 2,   // AAC-LC; HE-AAC is re-encoded
           (1...2).contains(asbd.mChannelsPerFrame),
           adtsFrequencyIndex(asbd.mSampleRate) != nil {
            copied = (asbd.mSampleRate, Int(asbd.mChannelsPerFrame))
        }

        let length = try await asset.load(.duration)
        let bounds = try keyframeBounds(asset: asset, video: video, end: length)
        return LocalStream(
            asset: asset, video: video, audio: audio, copiedAudio: copied,
            parameterSets: sets, nalLength: Int(header), bounds: bounds,
            duration: length.seconds
        )
    }

    private static func keyframeBounds(asset: AVAsset, video: AVAssetTrack, end: CMTime) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure.unreadable }
        var bounds: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0, isKeyframe(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if let last = bounds.last, (time - last).seconds < targetSeconds { continue }
            bounds.append(time)
        }
        guard !bounds.isEmpty else { throw Failure.unreadable }
        bounds.append(end)
        return bounds
    }

    // MARK: serving

    func playlist(root: String) -> String {
        var lengths: [Double] = []
        for i in 0..<(bounds.count - 1) { lengths.append((bounds[i + 1] - bounds[i]).seconds) }
        var text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int((lengths.max() ?? Self.targetSeconds).rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD

        """
        for (i, length) in lengths.enumerated() {
            text += "#EXTINF:\(String(format: "%.3f", length)),\n\(root)/\(i).ts\n"
        }
        return text + "#EXT-X-ENDLIST\n"
    }

    /// Segment `n`, built if need be. Blocks the server thread asking for it,
    /// for up to a minute.
    func segment(_ n: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard n >= 0, n < bounds.count - 1, !closed else { return nil }
        requested = n
        // Waiting is right when the producer is on it or just behind it — the
        // receiver fetches a few ahead. Anything else is a seek.
        if ready[n] == nil {
            let onTheWay = producing.map { n >= $0 && n <= $0 + 3 } ?? false
            if !onTheWay { restart(from: n) }
        }
        lock.broadcast()
        let deadline = Date().addingTimeInterval(60)
        while ready[n] == nil, !closed {
            if !lock.wait(until: deadline) { return nil }
        }
        for key in ready.keys where key < n - 2 || key > n + 10 { ready[key] = nil }
        return ready[n]
    }

    func close() {
        lock.lock()
        closed = true
        generation += 1
        ready.removeAll()
        lock.broadcast()
        lock.unlock()
    }

    // MARK: producing

    /// Called with the lock held.
    private func restart(from n: Int) {
        generation += 1
        producing = n
        let current = generation
        Thread { [self] in produce(from: n, generation: current) }.start()
    }

    private func isCurrent(_ g: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return g == generation && !closed
    }

    /// Hands a finished segment over, then holds the producer back while it is
    /// well ahead of what the receiver has asked for.
    private func publish(_ n: Int, _ data: Data, generation g: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard g == generation, !closed else { return false }
        ready[n] = data
        producing = n + 1
        lock.broadcast()
        while g == generation, !closed, n + 1 > requested + 4 {
            _ = lock.wait(until: Date().addingTimeInterval(1))
        }
        return g == generation && !closed
    }

    private func produce(from start: Int, generation g: Int) {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        reader.timeRange = CMTimeRange(start: bounds[start], end: bounds[bounds.count - 1])
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        var sound: SoundSource?
        if let audio {
            if let copiedAudio {
                let out = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
                reader.add(out)
                sound = .copied(out, copiedAudio.sampleRate, copiedAudio.channels)
            } else if let encoder = AACEncoder() {
                let out = AVAssetReaderAudioMixOutput(audioTracks: [audio], audioSettings: AACEncoder.inputSettings)
                reader.add(out)
                sound = .encoded(out, encoder)
            }
        }
        guard reader.startReading() else { return }
        defer { reader.cancelReading() }

        var audioQueue: [(pts: Int64, frame: [UInt8])] = []
        var audioDone = sound == nil
        let floor = Self.ticks(bounds[start])

        /// Pulls audio until its queue reaches `limit`, in 90 kHz ticks.
        func fillAudio(until limit: Int64) {
            while !audioDone, (audioQueue.last?.pts ?? Int64.min) < limit {
                guard let sound, let frames = sound.next() else { audioDone = true; break }
                audioQueue += frames.filter { $0.pts >= floor - 9_000 }
            }
        }

        var n = start
        var writer = TSWriter(audio: sound != nil)
        while let sample = videoOut.copyNextSampleBuffer() {
            guard isCurrent(g) else { return }
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let pts = Self.ticks(CMSampleBufferGetPresentationTimeStamp(sample))
            let decode = CMSampleBufferGetDecodeTimeStamp(sample)
            let dts = decode.isValid ? Self.ticks(decode) : pts
            let keyframe = Self.isKeyframe(sample)

            if keyframe, n + 1 < bounds.count - 1, pts >= Self.ticks(bounds[n + 1]) {
                let edge = Self.ticks(bounds[n + 1])
                fillAudio(until: edge)
                while let first = audioQueue.first, first.pts < edge {
                    writer.audio(first.frame, pts: first.pts + Self.offset)
                    audioQueue.removeFirst()
                }
                guard publish(n, writer.data, generation: g) else { return }
                n += 1
                writer = TSWriter(audio: sound != nil)
            }

            fillAudio(until: dts + 27_000)
            while let first = audioQueue.first, first.pts <= dts {
                writer.audio(first.frame, pts: first.pts + Self.offset)
                audioQueue.removeFirst()
            }
            writer.video(annexB(sample, keyframe: keyframe), pts: pts + Self.offset, dts: dts + Self.offset)
        }
        fillAudio(until: .max)
        for frame in audioQueue { writer.audio(frame.frame, pts: frame.pts + Self.offset) }
        _ = publish(n, writer.data, generation: g)
    }

    /// AVCC to Annex B: an access unit delimiter, the parameter sets in front
    /// of every keyframe, and a start code in place of each length.
    private func annexB(_ sample: CMSampleBuffer, keyframe: Bool) -> [UInt8] {
        var out: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
        if keyframe { for set in parameterSets { out += [0, 0, 0, 1] + set } }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return out }
        let size = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: size)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &bytes) == noErr
        else { return out }
        var i = 0
        while i + nalLength <= size {
            var length = 0
            for k in 0..<nalLength { length = length << 8 | Int(bytes[i + k]) }
            i += nalLength
            guard length > 0, i + length <= size else { break }
            if bytes[i] & 0x1F != 9 { out += [0, 0, 0, 1] + bytes[i..<(i + length)] }
            i += length
        }
        return out
    }

    // MARK: helpers

    private static func ticks(_ time: CMTime) -> Int64 {
        Int64((time.seconds * 90_000).rounded())
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first
        else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    fileprivate static func adtsFrequencyIndex(_ rate: Double) -> Int? {
        [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
            .firstIndex(of: Int(rate))
    }

    private static func fourCC(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}

// MARK: - sound

/// Where a segment's audio frames come from: copied out of the file, or
/// decoded by the reader and encoded here. Either way, ADTS frames with their
/// presentation time in 90 kHz ticks.
private enum SoundSource {
    case copied(AVAssetReaderOutput, Double, Int)
    case encoded(AVAssetReaderOutput, AACEncoder)

    func next() -> [(pts: Int64, frame: [UInt8])]? {
        switch self {
        case let .copied(output, rate, channels):
            guard let sample = output.copyNextSampleBuffer() else { return nil }
            return Self.packets(sample).enumerated().map { index, packet in
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let pts = Int64(((start + Double(index) * 1024 / rate) * 90_000).rounded())
                return (pts, adts(packet, rate: rate, channels: channels))
            }
        case let .encoded(output, encoder):
            // The reader is done: one last drain, then nil, so the caller
            // stops asking.
            guard let sample = output.copyNextSampleBuffer() else {
                guard !encoder.isFinished else { return nil }
                return encoder.flush().map { ($0.pts, adts($0.frame, rate: AACEncoder.rate, channels: 2)) }
            }
            return encoder.encode(sample).map { ($0.pts, adts($0.frame, rate: AACEncoder.rate, channels: 2)) }
        }
    }

    private static func packets(_ sample: CMSampleBuffer) -> [[UInt8]] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let size = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: size)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &bytes) == noErr
        else { return [] }
        var needed = 0
        CMSampleBufferGetAudioStreamPacketDescriptions(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
        guard needed > 0 else { return [bytes] }
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: needed)
        CMSampleBufferGetAudioStreamPacketDescriptions(
            sample, entryCount: needed, arrayToFill: &descriptions, entriesNeededOut: nil
        )
        return descriptions.compactMap { d in
            let start = Int(d.mStartOffset), end = start + Int(d.mDataByteSize)
            return end <= size ? Array(bytes[start..<end]) : nil
        }
    }

    private func adts(_ payload: [UInt8], rate: Double, channels: Int) -> [UInt8] {
        let index = LocalStream.adtsFrequencyIndex(rate) ?? 3
        let length = payload.count + 7
        let header: [UInt8] = [
            0xFF, 0xF1,
            UInt8((1 << 6) | (index << 2) | ((channels >> 2) & 1)),   // AAC-LC
            UInt8(((channels & 3) << 6) | ((length >> 11) & 0x03)),
            UInt8((length >> 3) & 0xFF),
            UInt8(((length & 7) << 5) | 0x1F),
            0xFC,
        ]
        return header + payload
    }
}

/// Stereo AAC-LC from 16-bit PCM, one 1024-frame packet at a time.
private final class AACEncoder {
    static let rate = 48_000.0
    static let inputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: 2,
        AVSampleRateKey: rate,
    ]
    private static let bytesPerFrame = 4
    /// What the encoder holds back before its first real sample.
    private static let priming = 2112

    private var converter: AudioConverterRef?
    fileprivate var pcm: [UInt8] = []
    fileprivate var feeding: [UInt8] = []
    private(set) var isFinished = false
    /// Presentation time of the first sample handed in, in seconds.
    private var origin: Double?
    private var packetsOut = 0

    init?() {
        var input = AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 2, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
        var bitrate: UInt32 = 160_000
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    func encode(_ sample: CMSampleBuffer) -> [(pts: Int64, frame: [UInt8])] {
        if origin == nil { origin = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
        if let block = CMSampleBufferGetDataBuffer(sample) {
            let size = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: size)
            if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &bytes) == noErr {
                pcm += bytes
            }
        }
        return drain()
    }

    /// What is left of the input, encoded. The encoder's last fraction of a
    /// packet stays behind — under 25 ms at the very end of the film.
    func flush() -> [(pts: Int64, frame: [UInt8])] {
        isFinished = true
        return drain()
    }

    private func drain() -> [(pts: Int64, frame: [UInt8])] {
        guard let converter, let origin else { return [] }
        var out: [(pts: Int64, frame: [UInt8])] = []
        let capacity = 6144
        while pcm.count >= 1024 * Self.bytesPerFrame {
            var buffer = [UInt8](repeating: 0, count: capacity)
            var produced: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(capacity), mData: raw.baseAddress)
                )
                return AudioConverterFillComplexBuffer(
                    converter, aacInput, Unmanaged.passUnretained(self).toOpaque(),
                    &produced, &list, &description
                )
            }
            guard produced > 0, status == noErr || status == noMoreInput else { break }
            let size = Int(description.mDataByteSize)
            let frameStart = packetsOut * 1024 - Self.priming
            packetsOut += 1
            // The priming packets carry nothing of the film.
            guard frameStart >= 0, size > 0, size <= capacity else { continue }
            let seconds = origin + Double(frameStart) / Self.rate
            out.append((Int64((seconds * 90_000).rounded()), Array(buffer[0..<size])))
        }
        return out
    }
}

/// "Nothing more right now", from the input callback. Any non-zero value the
/// converter does not itself use will do.
private let noMoreInput: OSStatus = 0x6E6F6D72   // 'nomr'

private let aacInput: AudioConverterComplexInputDataProc = { _, packets, data, _, context in
    guard let context else { return noMoreInput }
    let encoder = Unmanaged<AACEncoder>.fromOpaque(context).takeUnretainedValue()
    let wanted = Int(packets.pointee) * 4
    let available = min(wanted, encoder.pcm.count)
    guard available > 0 else {
        packets.pointee = 0
        return noMoreInput
    }
    // Kept on the encoder: the converter reads it after this returns.
    encoder.feeding = Array(encoder.pcm[0..<available])
    encoder.pcm.removeFirst(available)
    packets.pointee = UInt32(available / 4)
    encoder.feeding.withUnsafeMutableBytes { raw in
        data.pointee.mBuffers.mData = raw.baseAddress
        data.pointee.mBuffers.mDataByteSize = UInt32(available)
        data.pointee.mBuffers.mNumberChannels = 2
    }
    return noErr
}

// MARK: - transport stream

/// One segment's worth of MPEG-TS: PAT and PMT up front, then PES packets.
private struct TSWriter {
    private(set) var bytes: [UInt8] = []
    private var counters: [Int: Int] = [:]
    private let hasAudio: Bool

    var data: Data { Data(bytes) }

    init(audio: Bool) {
        hasAudio = audio
        bytes += section(pid: 0x0000, table: [
            0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
            0x00, 0x01, 0xF0, 0x00,   // program 1 -> PMT 0x1000
        ])
        var streams: [UInt8] = [0x1B, 0xE1, 0x00, 0xF0, 0x00]
        if audio { streams += [0x0F, 0xE1, 0x01, 0xF0, 0x00] }
        let length = 9 + streams.count + 4
        bytes += section(pid: 0x1000, table: [
            0x02, UInt8(0xB0 | ((length >> 8) & 0x0F)), UInt8(length & 0xFF),
            0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE1, 0x00,               // PCR on the video
            0xF0, 0x00,
        ] + streams)
    }

    mutating func video(_ payload: [UInt8], pts: Int64, dts: Int64) {
        let header: [UInt8] = [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0xC0, 0x0A]
            + stamp(0x3, pts) + stamp(0x1, dts)
        packetize(pid: 0x0100, header + payload, pcr: dts - 9_000)
    }

    mutating func audio(_ frame: [UInt8], pts: Int64) {
        guard hasAudio else { return }
        let length = 3 + 5 + frame.count
        let header: [UInt8] = [0x00, 0x00, 0x01, 0xC0, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
                               0x80, 0x80, 0x05] + stamp(0x2, pts)
        packetize(pid: 0x0101, header + frame, pcr: nil)
    }

    private func stamp(_ prefix: UInt8, _ time: Int64) -> [UInt8] {
        let t = UInt64(max(0, time)) & 0x1_FFFF_FFFF
        return [
            (prefix << 4) | UInt8((t >> 29) & 0x0E) | 1,
            UInt8((t >> 22) & 0xFF),
            UInt8((t >> 14) & 0xFE) | 1,
            UInt8((t >> 7) & 0xFF),
            UInt8((t << 1) & 0xFE) | 1,
        ]
    }

    private mutating func packetize(pid: Int, _ data: [UInt8], pcr: Int64?) {
        var offset = 0
        var first = true
        while offset < data.count {
            var field: [UInt8]?
            if first, let pcr {
                let b = UInt64(max(0, pcr)) & 0x1_FFFF_FFFF
                field = [0x10, UInt8((b >> 25) & 0xFF), UInt8((b >> 17) & 0xFF),
                         UInt8((b >> 9) & 0xFF), UInt8((b >> 1) & 0xFF), UInt8((b & 1) << 7) | 0x7E, 0x00]
            }
            var room = 184 - (field.map { $0.count + 1 } ?? 0)
            let remaining = data.count - offset
            if remaining < room {
                let stuffing = room - remaining
                if var existing = field {
                    existing += [UInt8](repeating: 0xFF, count: stuffing)
                    field = existing
                } else {
                    field = stuffing == 1 ? [] : [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                }
                room = remaining
            }
            let counter = counters[pid, default: 0]
            counters[pid] = (counter + 1) & 0x0F
            bytes += [
                0x47,
                UInt8((first ? 0x40 : 0) | ((pid >> 8) & 0x1F)),
                UInt8(pid & 0xFF),
                UInt8((field == nil ? 0x10 : 0x30) | counter),
            ]
            if let field {
                bytes.append(UInt8(field.count))
                bytes += field
            }
            bytes += data[offset..<(offset + room)]
            offset += room
            first = false
        }
    }

    private func section(pid: Int, table: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [0x47, UInt8(0x40 | ((pid >> 8) & 0x1F)), UInt8(pid & 0xFF), 0x10, 0x00]
        packet += table
        let crc = CastRemux.TS.crc32(table)
        packet += [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
                   UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
        packet += [UInt8](repeating: 0xFF, count: 188 - packet.count)
        return packet
    }
}
