import AVKit
import UIKit
import CoreMedia
import CoreVideo

/// Picture-in-Picture for the VLC player.
///
/// AVKit PiP only knows two content sources: an `AVPlayerLayer` or an
/// `AVSampleBufferDisplayLayer`. VLC renders to a plain `UIView` (Metal/GL) and
/// exposes no decoded-frame callback, so the bridge *snapshots the drawable* on a
/// `CADisplayLink` and enqueues each frame into a sample-buffer layer that PiP
/// then mirrors into the floating window.
///
/// Cost/limits, by design:
///   • Capture is a `drawHierarchy` per tick — throttled to ~15 fps to stay cheap.
///   • It reflects whatever VLC has on screen; if the OS suspends VLC's decode in
///     the background the picture freezes (audio, via background-audio mode, runs).
/// The button is hidden when `possible == false` (Simulator / unsupported device).
///
/// Not `@MainActor`: the two *return-value* PiP delegates (`timeRangeForPlayback`,
/// `isPlaybackPaused`) are synchronous, so they read plain cached primitives that a
/// small main-actor poll keeps fresh — no actor hop, no iOS-17 `assumeIsolated`.
final class VLCPiPController: NSObject, ObservableObject {
    @Published private(set) var active = false
    let possible = AVPictureInPictureController.isPictureInPictureSupported()

    private weak var source: UIView?
    private weak var model: VLCPlayerModel?

    private let bufferLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var link: CADisplayLink?
    private var cacheTask: Task<Void, Never>?

    // Read synchronously by the PiP delegates; written on the main actor by the poll.
    private var cachedTotal: Double = 0
    private var cachedPaused = true

    init(source: UIView, model: VLCPlayerModel) {
        self.source = source
        self.model = model
        super.init()
        setup()
    }

    private func setup() {
        guard possible, let source else { return }
        bufferLayer.videoGravity = .resizeAspect
        bufferLayer.frame = source.bounds
        // Inserted at index 0 so the VLC drawable (a sibling above it) fully
        // occludes it — kept visible rather than hidden, which some iOS versions
        // require for a sample-buffer layer to be a valid PiP source.
        source.superview?.layer.insertSublayer(bufferLayer, at: 0)

        let content = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: bufferLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: content)
        pip.delegate = self
        controller = pip
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            startLink(); startCachePoll()
            controller.startPictureInPicture()
        }
    }

    func teardown() {
        stopLink(); cacheTask?.cancel(); cacheTask = nil
        controller?.stopPictureInPicture()
        bufferLayer.removeFromSuperlayer()
    }

    // MARK: cache poll (keeps the synchronous delegates cheap & isolation-free)

    private func startCachePoll() {
        cacheTask?.cancel()
        cacheTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let m = self?.model {
                    self?.cachedTotal = m.totalSeconds
                    self?.cachedPaused = !m.isPlaying
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: frame pump

    private func startLink() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(step))
        // afterScreenUpdates:true (below) forces a real render each capture, so
        // keep the rate modest.
        l.preferredFramesPerSecond = 10
        l.add(to: .main, forMode: .common)
        link = l
    }
    private func stopLink() { link?.invalidate(); link = nil }

    @objc private func step() {
        guard let source, source.bounds.width > 1,
              bufferLayer.status != .failed,
              let pb = snapshot(source),
              let sb = sampleBuffer(from: pb)
        else { return }
        if bufferLayer.isReadyForMoreMediaData { bufferLayer.enqueue(sb) }
    }

    /// Render the live drawable into a BGRA pixel buffer.
    private func snapshot(_ view: UIView) -> CVPixelBuffer? {
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return nil }

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1                    // PiP is small; native scale wastes work
        fmt.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            // afterScreenUpdates MUST be true: VLC renders via a Metal/GL layer,
            // and only a post-update snapshot captures GPU-composited content —
            // with false the capture is black, which is why PiP showed nothing.
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return nil }

        let w = cg.width, h = cg.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }

    private func sampleBuffer(from pb: CVPixelBuffer) -> CMSampleBuffer? {
        var fmtDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb,
            formatDescriptionOut: &fmtDesc) == noErr, let fd = fmtDesc
        else { return nil }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: now, decodeTimeStamp: .invalid)

        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pb,
            formatDescription: fd, sampleTiming: &timing,
            sampleBufferOut: &sb) == noErr, let sample = sb
        else { return nil }

        if let attach = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attach) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attach, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - PiP delegates (called by AVKit on the main thread)

extension VLCPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        active = true
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        active = false; stopLink(); cacheTask?.cancel(); cacheTask = nil
    }
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        active = false; stopLink()
    }
}

extension VLCPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor [weak self] in
            guard let m = self?.model else { return }
            if playing { m.player.play() } else { m.player.pause() }
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController) -> CMTimeRange {
        // Rendered as the PiP scrubber. Live/unknown-length streams get a large
        // window so the bar doesn't read as "ended".
        let total = cachedTotal > 0 ? cachedTotal : 3600
        return CMTimeRange(start: .zero, duration: CMTime(seconds: total, preferredTimescale: 1))
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController) -> Bool { cachedPaused }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            self?.model?.skip(Int(skipInterval.seconds))
            completionHandler()
        }
    }
}
