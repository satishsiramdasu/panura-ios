import AVFoundation
import Foundation

/// Makes a local video safe to put on a TV.
///
/// An iPhone records HEVC in **Dolby Vision profile 8.4**, and a TV that
/// advertises DV support will take that bitstream down its DV path and then
/// mis-decode it — bands of noise and striping, with the geometry intact.
/// Nothing is wrong with the file or with how it reached the TV: Apple's own
/// decoder plays it perfectly, which is why the same video looks right on the
/// phone. The weak link is the television, and it is not ours to fix.
///
/// So anything the TV is likely to get wrong is exported to plain **H.264 SDR**
/// first. The copy is cached, because converting the same holiday clip twice is
/// pure waste, and it lives in the temporary directory so the system can reclaim
/// it on its own terms.
///
/// What is *not* converted matters as much: an H.264 clip is already the thing
/// every receiver handles, so it goes straight out. Converting unconditionally
/// would make the common case slower for nothing.
enum CastTranscoder {
    /// Why a video is being converted, so the sheet can say something true
    /// rather than "preparing".
    enum Reason {
        case dolbyVision, hdr, hevcForChromecast

        var explanation: String {
            switch self {
            case .dolbyVision:
                return "This clip is Dolby Vision. Most TVs render it as noise, so Panura is making a standard copy."
            case .hdr:
                return "This clip is HDR. Converting it to standard range so the TV shows the right colours."
            case .hevcForChromecast:
                return "Chromecast cannot decode HEVC. Panura is making an H.264 copy."
            }
        }
    }

    /// Where the video is going. A Chromecast and Panura on Android TV do not
    /// fail on the same things, and converting for a limit the receiver does not
    /// have is wasted minutes.
    enum Target {
        /// Our own receiver — it runs the same player this app does, so it
        /// handles HEVC. Dolby Vision is still the TV panel's problem.
        case panura
        /// Plays MP4 and WebM, and most models cannot decode HEVC at all.
        case chromecast
    }

    enum Failure: Error {
        case noVideoTrack, exportFailed(String), cancelled
    }

    /// Decides whether `url` needs converting for `target`, and says why.
    ///
    /// Reads the track's own format description rather than trusting the file
    /// extension: `.mov` says nothing about what is inside it, and the whole
    /// problem here is a container whose contents the TV mishandles.
    static func reason(for url: URL, target: Target) async -> Reason? {
        guard let track = try? await AVURLAsset(url: url)
            .loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first
        else { return nil }

        let codec = CMFormatDescriptionGetMediaSubType(description)
        // 'dvh1'/'dvhe' are Dolby Vision; they are the reason this file exists.
        if codec == fourCC("dvh1") || codec == fourCC("dvhe") { return .dolbyVision }

        // A DV clip can also arrive tagged as ordinary HEVC with a DV
        // configuration box alongside, so ask the extensions too.
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        if extensions.keys.contains(where: { $0.contains("DolbyVision") || $0 == "dvcC" || $0 == "dvvC" }) {
            return .dolbyVision
        }

        // PQ and HLG are the two HDR transfer functions. An SDR TV fed either
        // shows washed-out or crushed colour rather than noise — less dramatic
        // than DV, still wrong.
        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
           transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
            return .hdr
        }

        let isHEVC = codec == fourCC("hvc1") || codec == fourCC("hev1")
        if isHEVC, target == .chromecast { return .hevcForChromecast }
        return nil
    }

    /// Exports an H.264 SDR copy, reporting progress, and hands back its URL.
    ///
    /// Cached by asset id: the second cast of the same video starts playing
    /// immediately. The cache is only trusted when the file is non-empty, so a
    /// run that was killed mid-export cannot leave a stub that plays as a
    /// truncated video forever.
    static func convert(
        _ url: URL,
        id: String,
        onProgress: @escaping (Float) -> Void
    ) async throws -> URL {
        let destination = cacheURL(for: id)
        if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber,
           size.int64Value > 0 {
            return destination
        }
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw Failure.noVideoTrack }

        // A resolution preset, not `HighestQuality`: the resolution presets are
        // the H.264 ones, and `HighestQuality` would happily hand back the HEVC
        // this exists to get rid of. 1080p because a phone shooting 4K DV is the
        // common case and a TV gains nothing from 4K over a phone's own Wi-Fi.
        let preset = AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure.exportFailed("This device cannot convert that video.")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        // Tone-maps HDR down to SDR rather than clipping it.
        session.videoComposition = try? await AVVideoComposition.videoComposition(
            withPropertiesOf: asset
        )

        let ticker = Task {
            while !Task.isCancelled {
                onProgress(session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { ticker.cancel() }

        // `export()`'s async form is iOS 18; this app runs back to 16.
        // Cancelling the surrounding task has to reach the export itself —
        // without this, Cancel would dismiss the sheet and leave the phone
        // transcoding in the background for nobody.
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                session.exportAsynchronously { cont.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }

        switch session.status {
        case .completed:
            onProgress(1)
            return destination
        case .cancelled:
            try? FileManager.default.removeItem(at: destination)
            throw Failure.cancelled
        default:
            try? FileManager.default.removeItem(at: destination)
            throw Failure.exportFailed(session.error?.localizedDescription ?? "The conversion failed.")
        }
    }

    /// Everything converted so far, so Settings can say what it is holding and
    /// offer to let it go.
    static func cacheSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static var directory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panura-cast", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cacheURL(for id: String) -> URL {
        let key = String(id.prefix(36)).replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(key).appendingPathExtension("mp4")
    }

    private static func fourCC(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}
