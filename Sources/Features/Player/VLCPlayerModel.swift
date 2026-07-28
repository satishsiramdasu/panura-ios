import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import VLCKitSPM

/// Wraps VLCMediaPlayer (libVLC) — plays every format AVPlayer can't and, unlike
/// AVPlayer, reliably honors HTTP Referer/User-Agent/Cookie headers, so
/// header-gated streams play. Publishes state for the SwiftUI control overlay.
@MainActor
final class VLCPlayerModel: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var position: Float = 0          // 0...1
    @Published var elapsed = "0:00"
    @Published var remaining = "-0:00"      // time left, e.g. "-12:34"
    @Published var total = "0:00"           // duration / end time, e.g. "36:04"
    @Published var buffering = true
    /// Non-nil when playback failed, so the UI says so instead of spinning.
    @Published var failure: String?
    @Published var rate: Float = 1.0

    @Published var audioTracks: [Track] = []
    @Published var subtitleTracks: [Track] = []
    @Published var currentAudioId: Int = -1
    @Published var currentSubtitleId: Int = -1

    /// Zoom mode, cycled by the aspect button / pinch.
    @Published var aspect: AspectMode = .fit
    /// Sidecar/embedded A-V sync offsets, in milliseconds (UI unit).
    @Published var subtitleDelayMs: Int = 0
    @Published var audioDelayMs: Int = 0

    struct Track: Identifiable, Hashable { let id: Int; let name: String }

    enum AspectMode: String, CaseIterable {
        case fit, fill, stretch
        var label: String {
            switch self {
            case .fit: return "Fit"
            case .fill: return "Fill"
            case .stretch: return "Stretch"
            }
        }
        var icon: String {
            switch self {
            case .fit: return "rectangle.arrowtriangle.2.inward"
            case .fill: return "rectangle.arrowtriangle.2.outward"
            case .stretch: return "arrow.up.left.and.arrow.down.right"
            }
        }
    }

    let player = VLCMediaPlayer()
    /// The libVLC drawable — held weakly so the PiP bridge can snapshot it.
    private(set) weak var drawableView: UIView?

    private var tracksLoaded = false
    private var item: MediaItem?
    private var observersAdded = false

    // char* options libVLC copies internally; we own the buffers and free on change.
    private var aspectPtr: UnsafeMutablePointer<CChar>?
    private var cropPtr: UnsafeMutablePointer<CChar>?

    // Resume-from-position bookkeeping.
    private var pendingResumeSeconds: Double?
    private var resumeApplied = false
    private var lastResumeSave = Date.distantPast

    // libVLC delay APIs are in MICROSECONDS (they pass straight through to
    // libvlc_video_set_spu_delay / libvlc_audio_set_delay). UI works in ms.
    private let usPerMs = 1000

    private var rateBeforeBoost: Float = 1.0

    /// User setting — when off, playback pauses as soon as the app leaves the
    /// foreground (screen lock, home). When on, audio keeps going.
    private var backgroundPlayEnabled: Bool {
        UserDefaults.standard.bool(forKey: "background_play")
    }

    /// Resume-from-last-position. Default on; stored as an inverted flag so the
    /// absent (fresh install) case reads as enabled.
    private var resumeEnabled: Bool {
        UserDefaults.standard.object(forKey: "resume_playback") as? Bool ?? true
    }

    // MARK: start

    func start(item: MediaItem, into view: UIView) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        self.item = item
        drawableView = view
        player.drawable = view
        player.delegate = self

        if resumeEnabled {
            let saved = UserDefaults.standard.double(forKey: Self.resumeKey(item.url))
            if saved > 15 { pendingResumeSeconds = saved }
        }

        buildAndPlay()
        setupRemoteCommands()
        observeLifecycle()
    }

    /// (Re)builds the VLCMedia and starts playback. Split out so a subtitle-style
    /// change can re-open the same item at its current position without touching
    /// the drawable, remote commands, or lifecycle observers.
    private func buildAndPlay() {
        guard let item else { return }

        // Two reasons to relay.
        // 1. Headers VLC cannot send — Origin and anything else we captured.
        //    Referer/UA/cookie it sets natively, so relaying those would buffer
        //    every segment through a local socket for nothing.
        // 2. An HLS stream nothing identifies as HLS. These CDNs serve an
        //    extensionless URL as text/plain, and libVLC chooses its demuxer by
        //    MIME and extension — so it never reaches the adaptive demuxer and
        //    simply fails. The relay re-serves it as application/vnd.apple.mpegurl.
        let needsHeaderRelay = item.headers.keys.contains {
            !Self.vlcNativeHeaders.contains($0.lowercased())
        }
        let path = item.url.path.lowercased()
        let looksLikeHLS = path.hasSuffix(".m3u8")
        let needsTypeRelay = item.contentType == "hls" && !looksLikeHLS

        let playURL = (needsHeaderRelay || needsTypeRelay)
            ? StreamProxy.shared.proxied(
                url: item.url,
                headers: item.headers,
                playlistHint: needsTypeRelay
              )
            : item.url

        let media = VLCMedia(url: playURL)
        applyHeaders(item.headers, to: media)     // belt-and-braces for the direct path
        applySubtitleStyle(to: media)
        player.media = media
        player.play()

        // Sidecar subtitles sniffed from the page — the stream itself usually
        // carries none, so without these there are no captions at all.
        for track in item.subtitles {
            player.addPlaybackSlave(track.url, type: .subtitle, enforce: false)
        }

        tracksLoaded = false
    }

    /// Headers libVLC can set itself, via the options in `applyHeaders`.
    private static let vlcNativeHeaders: Set<String> = ["referer", "user-agent", "cookie"]

    /// libVLC honors these per-media options; covers the common gating headers.
    private func applyHeaders(_ headers: [String: String], to media: VLCMedia) {
        func value(_ keys: String...) -> String? {
            for k in keys { if let v = headers[k] { return v } }
            return nil
        }
        if let referer = value("Referer", "referer") {
            media.addOption(":http-referrer=\(referer)")
        }
        if let ua = value("User-Agent", "user-agent") {
            media.addOption(":http-user-agent=\(ua)")
        }
        if let cookie = value("Cookie", "cookie") {
            media.addOption(":http-cookie=\(cookie)")
        }
    }

    /// Subtitle look — set at media-open time (libVLC's text renderer reads these
    /// on start). Live changes re-open the media via `reopenPreservingPosition`.
    private func applySubtitleStyle(to media: VLCMedia) {
        let size = UserDefaults.standard.object(forKey: "subtitle_size") as? Int ?? 24
        let color = UserDefaults.standard.object(forKey: "subtitle_color") as? Int ?? 0xFFFFFF
        media.addOption(":freetype-fontsize=\(size)")
        media.addOption(":freetype-color=\(color)")
        // A soft outline keeps white text legible over bright frames.
        media.addOption(":freetype-outline-thickness=4")
    }

    /// Re-open the current item at the current playhead — used when a subtitle
    /// size/color change needs to take effect immediately.
    func reopenPreservingPosition() {
        let atSeconds = Double(player.time.intValue) / 1000
        pendingResumeSeconds = atSeconds > 2 ? atSeconds : nil
        resumeApplied = false
        buildAndPlay()
    }

    // MARK: transport

    func togglePlay() { player.isPlaying ? player.pause() : player.play() }

    /// Skip amount (seconds) — user-configurable, default 10.
    var skipInterval: Int {
        let v = UserDefaults.standard.integer(forKey: "skip_interval")
        return v > 0 ? v : 10
    }
    func skipForward()  { player.jumpForward(Int32(skipInterval)) }
    func skipBackward() { player.jumpBackward(Int32(skipInterval)) }
    func skip(_ seconds: Int) {
        seconds >= 0 ? player.jumpForward(Int32(seconds)) : player.jumpBackward(Int32(-seconds))
    }

    func seek(to fraction: Float) { player.position = max(0, min(1, fraction)) }
    func setRate(_ r: Float) { player.rate = r; rate = r }

    /// Hold-to-speed-up (long press): remember the rate, jump to 2×, restore.
    func beginSpeedBoost() { rateBeforeBoost = player.rate; setRate(2.0) }
    func endSpeedBoost()   { setRate(rateBeforeBoost) }

    func stop() {
        saveResume()
        player.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let p = aspectPtr { free(p); aspectPtr = nil }
        if let p = cropPtr { free(p); cropPtr = nil }
        ScreenBrightness.restore()
    }

    func selectAudio(_ id: Int) {
        player.currentAudioTrackIndex = Int32(id); currentAudioId = id
    }
    func selectSubtitle(_ id: Int) {
        player.currentVideoSubTitleIndex = Int32(id); currentSubtitleId = id
    }

    // MARK: aspect / zoom

    func cycleAspect() {
        let all = AspectMode.allCases
        let i = all.firstIndex(of: aspect) ?? 0
        aspect = all[(i + 1) % all.count]
        applyAspect()
    }

    private func applyAspect() {
        let size = drawableView?.bounds.size ?? UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let w = max(1, Int(size.width * scale))
        let h = max(1, Int(size.height * scale))
        switch aspect {
        case .fit:     setCrop(nil);        setAspectRatio(nil)
        case .fill:    setAspectRatio(nil); setCrop("\(w):\(h)")
        case .stretch: setCrop(nil);        setAspectRatio("\(w):\(h)")
        }
    }

    private func setAspectRatio(_ s: String?) {
        player.videoAspectRatio = nil
        if let old = aspectPtr { free(old); aspectPtr = nil }
        if let s { let p = strdup(s); aspectPtr = p; player.videoAspectRatio = p }
    }
    private func setCrop(_ s: String?) {
        player.videoCropGeometry = nil
        if let old = cropPtr { free(old); cropPtr = nil }
        if let s { let p = strdup(s); cropPtr = p; player.videoCropGeometry = p }
    }

    // MARK: A-V sync

    func adjustSubtitleDelay(_ deltaMs: Int) {
        subtitleDelayMs += deltaMs
        player.currentVideoSubTitleDelay = subtitleDelayMs * usPerMs
    }
    func adjustAudioDelay(_ deltaMs: Int) {
        audioDelayMs += deltaMs
        player.currentAudioPlaybackDelay = audioDelayMs * usPerMs
    }
    func resetSync() {
        subtitleDelayMs = 0; audioDelayMs = 0
        player.currentVideoSubTitleDelay = 0
        player.currentAudioPlaybackDelay = 0
    }
    private func reapplySync() {
        player.currentVideoSubTitleDelay = subtitleDelayMs * usPerMs
        player.currentAudioPlaybackDelay = audioDelayMs * usPerMs
    }

    // MARK: helpers exposed to the view

    var totalSeconds: Double {
        let e = Double(player.time.intValue) / 1000
        let r = Double(abs(player.remainingTime?.intValue ?? 0)) / 1000
        return e + r
    }
    var elapsedSeconds: Double { Double(player.time.intValue) / 1000 }

    static func clock(_ seconds: Double) -> String { fmt(Int32(max(0, seconds) * 1000)) }

    // MARK: lock screen / Control Center

    /// Populate the Now Playing card. VLC (unlike AVPlayer) never does this for
    /// us, which is why no media notification appeared.
    private func updateNowPlaying() {
        let elapsedMs = Int(player.time.intValue)
        let remainingMs = abs(Int(player.remainingTime?.intValue ?? 0))
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: (item?.title.isEmpty == false ? item!.title : "Panura"),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(elapsedMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
        ]
        let durationMs = elapsedMs + remainingMs
        if durationMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.play() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }; return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Int(self.player.time.intValue)
                let total = elapsed + abs(Int(self.player.remainingTime?.intValue ?? 0))
                if total > 0 {
                    self.seek(to: Float(e.positionTime * 1000 / Double(total)))
                }
            }
            return .success
        }
    }

    // MARK: background behaviour

    private func observeLifecycle() {
        guard !observersAdded else { return }
        observersAdded = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.backgroundPlayEnabled else { return }
                self.player.pause()
            }
        }
    }

    // MARK: resume

    private static func resumeKey(_ url: URL) -> String {
        // Stable across launches — Swift's String.hashValue is per-process seeded,
        // so it must NOT be used here or cross-session resume never matches.
        "resume_" + url.absoluteString
    }

    private func applyResumeIfPending() {
        let total = totalSeconds
        guard !resumeApplied, let target = pendingResumeSeconds, total > 0 else { return }
        // Only seek once the tail leaves room — never resume into the last 15s.
        guard target < total - 15 else { resumeApplied = true; return }
        player.position = Float(target / total)     // position is read-write across VLCKit builds
        resumeApplied = true
    }

    private func saveResume() {
        guard resumeEnabled, let item else { return }
        let e = elapsedSeconds, total = totalSeconds
        if total > 0, e > 15, e < total - 15 {
            UserDefaults.standard.set(e, forKey: Self.resumeKey(item.url))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.resumeKey(item.url))
        }
    }

    // MARK: track loading

    private func loadTracksIfNeeded() {
        guard !tracksLoaded else { return }
        // VLC prepends a synthetic index -1 ("Disable"); drop it — the sheets
        // offer their own "Off" row.
        let aIdx = (player.audioTrackIndexes as? [NSNumber]) ?? []
        let aName = (player.audioTrackNames as? [String]) ?? []
        audioTracks = zip(aIdx, aName)
            .compactMap { $0.intValue >= 0 ? Track(id: $0.intValue, name: $1) : nil }

        let sIdx = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        let sName = (player.videoSubTitlesNames as? [String]) ?? []
        subtitleTracks = zip(sIdx, sName)
            .compactMap { $0.intValue >= 0 ? Track(id: $0.intValue, name: $1) : nil }

        currentAudioId = Int(player.currentAudioTrackIndex)
        currentSubtitleId = Int(player.currentVideoSubTitleIndex)

        if !audioTracks.isEmpty || !subtitleTracks.isEmpty { tracksLoaded = true }
    }

    private static func fmt(_ ms: Int32) -> String {
        let total = max(0, Int(ms) / 1000)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

extension VLCPlayerModel: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            isPlaying = player.isPlaying
            switch player.state {
            case .buffering, .opening: buffering = !player.isPlaying
            case .playing:
                buffering = false; failure = nil
                loadTracksIfNeeded()
                reapplySync()
                applyAspect()
            case .error:
                buffering = false
                failure = "This stream could not be opened."
            default: break
            }
            updateNowPlaying()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            position = player.position
            // remainingTime is NEGATIVE; abs it, then derive the end time so the
            // duration shows even when the stream reports no length up front.
            let elapsedMs = player.time.intValue
            let remMs = abs(player.remainingTime?.intValue ?? 0)
            elapsed = Self.fmt(elapsedMs)
            remaining = "-" + Self.fmt(remMs)
            total = Self.fmt(elapsedMs + remMs)
            buffering = false
            loadTracksIfNeeded()
            applyResumeIfPending()
            updateNowPlaying()

            // Throttle resume persistence to ~5s.
            if Date().timeIntervalSince(lastResumeSave) > 5 {
                lastResumeSave = Date(); saveResume()
            }
        }
    }
}
