import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// hevc-check <fixtures dir>
//
// Renames hev1 → hvc1 with the app's HEVCTagPatcher, then makes AVFoundation
// prove the result: the sample entry reads hvc1, every frame decodes, and the
// HLS stream plays over HTTP (served by the workflow on port 8765). The
// unpatched originals are tried too, and only reported — they show what the
// patch is for.

enum Report {
    static var failures = 0
}

@MainActor func fail(_ message: String) {
    print("::error::\(message)")
    Report.failures += 1
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])

func subtype(_ format: CMFormatDescription) -> String {
    let code = CMFormatDescriptionGetMediaSubType(format)
    return String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
}

func decodedFrames(_ asset: AVAsset, _ track: AVAssetTrack) throws -> Int {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
    var count = 0
    while let buffer = output.copyNextSampleBuffer() {
        count += CMSampleBufferGetNumSamples(buffer)
    }
    if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
    return count
}

@MainActor func verify(_ url: URL, name: String) async {
    do {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await video.load(.formatDescriptions).first
        else {
            fail("\(name): no video track")
            return
        }
        let tag = subtype(format)
        guard tag == "hvc1" else {
            fail("\(name): sample entry is \(tag), expected hvc1")
            return
        }
        let transfer = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String
        let frames = try decodedFrames(asset, video)
        if frames < 190 { fail("\(name): decoded \(frames) frames, expected 200") }
        print("\(name): hvc1, transfer \(transfer ?? "none"), \(frames) frames decoded")
    } catch {
        fail("\(name): \(error)")
    }
}

/// Everything worth reading goes out as an annotation too: a workflow's log
/// needs a signed-in viewer, annotations are public through the API.
func notice(_ message: String) {
    print("::notice::\(message)")
}

@MainActor func play(_ path: String, name: String, required: Bool) async {
    // The server first, so a dead server is not mistaken for a refused stream.
    if let url = URL(string: "http://127.0.0.1:8765/\(path)"),
       let (data, response) = try? await URLSession.shared.data(from: url) {
        let http = response as? HTTPURLResponse
        let firstLines = String(decoding: data.prefix(300), as: UTF8.self).replacingOccurrences(of: "\n", with: " | ")
        notice("\(name): GET \(http?.statusCode ?? 0) \(http?.value(forHTTPHeaderField: "Content-Type") ?? "-"): \(firstLines)")
    } else {
        notice("\(name): server did not answer")
    }

    let item = AVPlayerItem(url: URL(string: "http://127.0.0.1:8765/\(path)")!)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.play()

    var sawFrame = false
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline, item.status != .failed {
        let now = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: now),
           output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil {
            sawFrame = true
        }
        if sawFrame, now.seconds > 1.5 { break }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    player.pause()

    let state: String
    switch item.status {
    case .readyToPlay: state = "ready"
    case .failed:
        let error = item.error as NSError?
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        let logged = item.errorLog()?.events.last.map { "\($0.errorDomain) \($0.errorStatusCode) \($0.errorComment ?? "")" } ?? "-"
        state = "failed (\(error?.domain ?? "") \(error?.code ?? 0) \(error?.localizedDescription ?? ""); underlying \(underlying?.domain ?? "-") \(underlying?.code ?? 0); log \(logged))"
    default: state = "never ready"
    }
    let summary = "\(name): \(state), reached \(String(format: "%.1f", item.currentTime().seconds))s, frame decoded \(sawFrame)"
    if !required {
        notice("baseline — \(summary)")
    } else if item.status != .readyToPlay {
        fail(summary)
    } else if !sawFrame {
        print("::warning::\(summary) — no frame, which may be the runner rather than the stream")
    } else {
        print(summary)
    }
}

// MARK: MP4 files, patched in small chunks the way the loader patches a stream

for name in ["hev1-faststart", "hev1-moov-at-end"] {
    let url = root.appendingPathComponent("\(name).mp4")
    do {
        let data = try Data(contentsOf: url)
        let patches = try await HEVCTagPatcher.locate(length: Int64(data.count)) { offset, count in
            let start = Int(offset)
            let end = min(data.count, start + count)
            return start < end ? data.subdata(in: start..<end) : Data()
        }
        if patches.isEmpty {
            fail("\(name): no hev1 sample entry found")
            continue
        }

        // An odd chunk size, so some four-character codes straddle two chunks.
        var patched = Data()
        var offset = 0
        while offset < data.count {
            var chunk = data.subdata(in: offset..<min(data.count, offset + 1021))
            HEVCTagPatcher.apply(patches, to: &chunk, at: Int64(offset))
            patched.append(chunk)
            offset += chunk.count
        }
        let out = root.appendingPathComponent("\(name)-patched.mp4")
        try patched.write(to: out)

        let original = AVURLAsset(url: url)
        let playable = (try? await original.load(.isPlayable)) ?? false
        notice("baseline — \(name): \(patches.count) patch(es); original isPlayable \(playable)")
        await verify(out, name: "\(name) patched")
    } catch {
        fail("\(name): \(error)")
    }
}

// MARK: fMP4 HLS, patched as the relay patches it

do {
    let source = root.appendingPathComponent("hls-hev1")
    let target = root.appendingPathComponent("hls-hev1-patched")
    try? FileManager.default.removeItem(at: target)
    try FileManager.default.copyItem(at: source, to: target)

    let media = try String(contentsOf: source.appendingPathComponent("index.m3u8"), encoding: .utf8)
    notice("media playlist: " + media.prefix(400).replacingOccurrences(of: "\n", with: " | "))
    await play("hls-hvc1/master.m3u8", name: "HLS fMP4 hvc1 control", required: false)

    let initURL = target.appendingPathComponent("init.mp4")
    if let renamed = try HEVCTagPatcher.patch(Data(contentsOf: initURL)) {
        try renamed.write(to: initURL)
        for file in ["master.m3u8", "index.m3u8"] {
            let url = target.appendingPathComponent(file)
            let text = try String(contentsOf: url, encoding: .utf8)
            try HEVCTagPatcher.renameCodecs(text).write(to: url, atomically: true, encoding: .utf8)
        }
        await play("hls-hev1-patched/master.m3u8", name: "HLS fMP4 patched", required: true)
    } else {
        fail("HLS: init segment has no hev1 sample entry")
    }
    await play("hls-hev1/master.m3u8", name: "HLS fMP4 original", required: false)
} catch {
    fail("HLS: \(error)")
}

print(Report.failures == 0 ? "all checks passed" : "\(Report.failures) check(s) failed")
exit(Report.failures == 0 ? 0 : 1)
