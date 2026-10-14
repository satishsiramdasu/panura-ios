import AVFoundation
import Foundation

/// The sound and the subtitles of a file on this phone, as a Chromecast needs
/// them.
///
/// **Chromecast only.** Panura on Android TV is sent the file untouched: it runs
/// the app's own player, which picks languages, decodes surround and reads
/// embedded subtitles by itself.
///
/// A Chromecast plays one audio track — the file's first — and the older ones,
/// built into Android 6 and 7 televisions, cannot decode Dolby or more than two
/// channels at all: the player closes, or plays pictures in silence. Nor does
/// it read subtitles out of the file. So a file with several languages has the
/// chosen one copied out on its own, surround is mixed down to stereo, and
/// embedded subtitles are lifted out and served beside it.
///
/// Unlike the streaming path, the sound *is* re-encoded here. A stream is
/// relayed live and every second of decoding is a second the phone must keep
/// up with; a file is prepared once, before it is sent, by a step that already
/// re-encodes the picture when it has to. The picture is copied as it is.
enum CastLocalMedia {
    struct AudioOption: Identifiable, Equatable, Sendable {
        /// Position among the file's audio tracks.
        let id: Int
        let label: String
        /// Dolby (AC-3, E-AC-3) or more than two channels.
        let isSurround: Bool
        let isAAC: Bool
    }

    struct EmbeddedSubtitle: Sendable {
        let label: String
        let language: String
        let cues: [SubtitleCue]
    }

    // MARK: audio

    static func audioOptions(of url: URL) async -> [AudioOption] {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return [] }
        var options: [AudioOption] = []
        for (index, track) in tracks.enumerated() {
            let description = (try? await track.load(.formatDescriptions))?.first
            let subtype = description.map(CMFormatDescriptionGetMediaSubType) ?? 0
            let channels = description
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                .map { Int($0.mChannelsPerFrame) } ?? 0
            let dolby = subtype == kAudioFormatAC3 || subtype == kAudioFormatEnhancedAC3
            let aac = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2]
                .contains(subtype)

            var label = await languageName(of: track) ?? "Track \(index + 1)"
            if dolby {
                label += " · Dolby"
            } else if channels > 2 {
                label += channels == 6 ? " · 5.1" : (channels == 8 ? " · 7.1" : " · \(channels) ch")
            }
            options.append(AudioOption(
                id: index, label: label, isSurround: dolby || channels > 2, isAAC: aac
            ))
        }
        return options
    }

    /// Whether the file has to be rebuilt before a Chromecast can play the
    /// chosen track. Several tracks always means yes: the receiver plays the
    /// first, whichever was chosen, so the chosen one has to be the only one.
    static func needsAudioFix(_ options: [AudioOption], chosen: AudioOption?) -> Bool {
        guard let chosen else { return false }
        return options.count > 1 || chosen.isSurround || !chosen.isAAC
    }

    static func explanation(_ options: [AudioOption], chosen: AudioOption) -> String {
        if chosen.isSurround {
            return "Chromecast can't play this file's surround sound, so Panura is making a stereo copy. The picture is copied as it is."
        }
        if options.count > 1 {
            return "Keeping only the language you chose, so the TV plays that one. The picture is copied as it is."
        }
        return "Converting the sound to a format Chromecast plays. The picture is copied as it is."
    }

    /// A copy holding the video untouched and only the chosen audio, as stereo
    /// AAC. Cached beside the other conversions.
    static func stereoCopy(
        _ url: URL,
        audio index: Int,
        id: String,
        onProgress: @escaping @Sendable (Float) -> Void
    ) async throws -> URL {
        let destination = CastTranscoder.cacheURL(for: id + "-a\(index)")
        if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber,
           size.int64Value > 0 {
            return destination
        }
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CastTranscoder.Failure.noVideoTrack
        }
        let sounds = try await asset.loadTracks(withMediaType: .audio)
        guard sounds.indices.contains(index) else {
            throw CastTranscoder.Failure.exportFailed("That audio track could not be read.")
        }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // The picture, byte for byte.
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: try await video.load(.formatDescriptions).first
        )
        videoIn.transform = try await video.load(.preferredTransform)
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        // The sound, decoded and mixed down to two channels by the reader,
        // then encoded to AAC.
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: [sounds[index]], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
        ])
        reader.add(audioOut)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 160_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        audioIn.expectsMediaDataInRealTime = false
        writer.add(audioIn)

        guard writer.startWriting(), reader.startReading() else {
            throw CastTranscoder.Failure.exportFailed(
                (writer.error ?? reader.error)?.localizedDescription ?? "The conversion failed."
            )
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(videoOut, into: videoIn, label: "cast.copy.video") { seconds in
                        if duration > 0 { onProgress(Float(min(1, seconds / duration))) }
                    }
                }
                group.addTask {
                    await pump(audioOut, into: audioIn, label: "cast.copy.audio", onTime: nil)
                }
            }
        } onCancel: {
            reader.cancelReading()
        }

        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw CastTranscoder.Failure.cancelled
        }
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw CastTranscoder.Failure.exportFailed(
                (reader.error ?? writer.error)?.localizedDescription ?? "The conversion failed."
            )
        }
        onProgress(1)
        return destination
    }

    /// Moves every sample from `output` to `input`, returning once the source
    /// is exhausted or the writer refuses one.
    private static func pump(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        label: String,
        onTime: ((Double) -> Void)?
    ) async {
        // A box, not a `var`: the block may be typed `@Sendable`, and a captured
        // variable cannot be mutated from one.
        final class Flag: @unchecked Sendable { var finished = false }
        let flag = Flag()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                guard !flag.finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        flag.finished = true
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                    onTime?(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                }
            }
        }
    }

    // MARK: subtitles

    /// Text subtitles carried inside an MP4 or MOV (`tx3g`, and WebVTT in MP4),
    /// as cues. Bitmap subtitles are not text and are left behind.
    static func embeddedSubtitles(of url: URL) async -> [EmbeddedSubtitle] {
        let asset = AVURLAsset(url: url)
        var tracks: [AVAssetTrack] = []
        for type in [AVMediaType.text, .subtitle] {
            tracks += (try? await asset.loadTracks(withMediaType: type)) ?? []
        }
        var found: [EmbeddedSubtitle] = []
        for (index, track) in tracks.prefix(8).enumerated() {
            guard let reader = try? AVAssetReader(asset: asset) else { continue }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            guard reader.startReading() else { continue }

            var cues: [SubtitleCue] = []
            while let buffer = output.copyNextSampleBuffer() {
                let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                let length = CMSampleBufferGetDuration(buffer).seconds
                guard start.isFinite, length.isFinite, length > 0,
                      let text = sampleText(buffer), !text.isEmpty
                else { continue }
                cues.append(SubtitleCue(start: start, end: start + length, text: text))
            }
            guard !cues.isEmpty else { continue }
            let language = await languageCode(of: track) ?? ""
            found.append(EmbeddedSubtitle(
                label: await languageName(of: track) ?? "Subtitles \(index + 1)",
                language: language,
                cues: cues
            ))
        }
        return found
    }

    /// The text of one subtitle sample. `tx3g` is a 16-bit length and then the
    /// string; WebVTT-in-MP4 keeps it in a `payl` box.
    private static func sampleText(_ buffer: CMSampleBuffer) -> String? {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let size = CMBlockBufferGetDataLength(block)
        guard size >= 2 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &bytes) == noErr
        else { return nil }

        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        if length > 0, length + 2 <= size,
           let text = String(bytes: bytes[2..<(2 + length)], encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let marker = Array("payl".utf8)
        if let at = (0...(max(0, size - 4))).first(where: { Array(bytes[$0..<min(size, $0 + 4)]) == marker }),
           at >= 4 {
            let boxSize = Int(bytes[at - 4]) << 24 | Int(bytes[at - 3]) << 16
                | Int(bytes[at - 2]) << 8 | Int(bytes[at - 1])
            let end = min(size, at - 4 + boxSize)
            if end > at + 4, let text = String(bytes: bytes[(at + 4)..<end], encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    // MARK: names

    private static func languageCode(of track: AVAssetTrack) async -> String? {
        let tag = (try? await track.load(.extendedLanguageTag)) ?? nil
        let code = (try? await track.load(.languageCode)) ?? nil
        let value = tag ?? code
        guard let value, !value.isEmpty, value != "und" else { return nil }
        return value
    }

    private static func languageName(of track: AVAssetTrack) async -> String? {
        guard let code = await languageCode(of: track) else { return nil }
        return Locale.current.localizedString(forIdentifier: code)?.capitalized ?? code
    }
}
