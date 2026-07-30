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
    @Published var displayTitle = ""        // current item title (updates on next/prev)
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

    /// Audio gain in percent (100 = normal, up to 200 = boost). NOT persisted —
    /// a fresh player always starts at 100, so it resets when the player closes.
    @Published var audioBoost: Int = 100

    /// HLS quality variants — populated only when the master playlist lists more
    /// than one. Empty otherwise, which is what hides the Quality button.
    @Published var qualities: [Quality] = []
    @Published var currentQualityId: String = Quality.auto.id

    /// nil until the real video dimensions arrive; then true for a portrait video.
    /// The view auto-rotates to match on change.
    @Published var videoIsPortrait: Bool?

    struct Track: Identifiable, Hashable { let id: Int; let name: String }

    /// A selectable HLS rendition. `url == nil` means Auto (adaptive = the master).
    struct Quality: Identifiable, Hashable {
        let id: String; let label: String; let url: URL?
        static let auto = Quality(id: "auto", label: "Auto", url: nil)
    }

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
    private var playURLOverride: URL?     // a specific HLS variant; nil = master / Auto
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

    /// The user's intended play/pause state — true while they want playback. Used
    /// to nudge VLC out of a post-seek buffering stall without overriding a
    /// deliberate pause.
    private var wantsPlayback = true

    /// Fires if a buffering state hangs; nudges VLC to resume. Cancelled on play.
    private var bufferWatchdog: Task<Void, Never>?

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
        displayTitle = item.title
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
        loadQualities()
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
        // Auto plays the master (item.url); a picked quality plays its variant URL.
        let sourceURL = playURLOverride ?? item.url
        let needsHeaderRelay = item.headers.keys.contains {
            !Self.vlcNativeHeaders.contains($0.lowercased())
        }
        let path = sourceURL.path.lowercased()
        let looksLikeHLS = path.hasSuffix(".m3u8")
        let needsTypeRelay = item.contentType == "hls" && !looksLikeHLS

        let playURL = (needsHeaderRelay || needsTypeRelay)
            ? StreamProxy.shared.proxied(
                url: sourceURL,
                headers: item.headers,
                playlistHint: needsTypeRelay
              )
            : sourceURL

        let media = VLCMedia(url: playURL)
        applyHeaders(item.headers, to: media)     // belt-and-braces for the direct path
        applySubtitleStyle(to: media)
        player.media = media
        player.play()
        wantsPlayback = true

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
        let background = UserDefaults.standard.bool(forKey: "subtitle_background")   // default off
        media.addOption(":freetype-fontsize=\(size)")
        media.addOption(":freetype-color=\(color)")
        // A soft outline keeps white text legible over bright frames.
        media.addOption(":freetype-outline-thickness=4")
        if background {
            // Opaque black box behind the glyphs for readability.
            media.addOption(":freetype-background-opacity=255")
            media.addOption(":freetype-background-color=0")
        }
    }

    /// Re-open the current item at the current playhead — used when a subtitle
    /// size/color change needs to take effect immediately.
    func reopenPreservingPosition() {
        let atSeconds = Double(player.time.intValue) / 1000
        pendingResumeSeconds = atSeconds > 2 ? atSeconds : nil
        resumeApplied = false
        buildAndPlay()
    }

    /// Switch to a different item in the same player — playlist next/previous.
    func play(item newItem: MediaItem) {
        saveResume()                       // persist the outgoing item's position
        self.item = newItem
        displayTitle = newItem.title
        videoIsPortrait = nil              // re-detect for the new video
        playURLOverride = nil
        qualities = []; currentQualityId = Quality.auto.id
        resetSync()                        // clears delays on model + player
        audioTracks = []; subtitleTracks = []
        currentAudioId = -1; currentSubtitleId = -1
        tracksLoaded = false
        pendingResumeSeconds = nil; resumeApplied = false
        if resumeEnabled {
            let saved = UserDefaults.standard.double(forKey: Self.resumeKey(newItem.url))
            if saved > 15 { pendingResumeSeconds = saved }
        }
        buildAndPlay()
        loadQualities()
    }

    // MARK: transport

    func togglePlay() {
        if player.isPlaying { player.pause(); wantsPlayback = false }
        else { player.play(); wantsPlayback = true }
    }

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

    func seek(to fraction: Float) {
        player.position = max(0, min(1, fraction))
        // VLC can wedge in the buffering state after a seek (notably local files),
        // leaving the spinner up and playback stalled — nudge it when the user
        // expects playback. Harmless if already playing.
        if wantsPlayback, !player.isPlaying { player.play() }
    }
    func setRate(_ r: Float) { player.rate = r; rate = r }

    /// Hold-to-speed-up (long press): remember the rate, jump to 2×, restore.
    func beginSpeedBoost() { rateBeforeBoost = player.rate; setRate(2.0) }
    func endSpeedBoost()   { setRate(rateBeforeBoost) }

    func stop() {
        bufferWatchdog?.cancel()
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

    /// Once the real dimensions are known, publish the video's orientation so the
    /// view can rotate to match (portrait clip → portrait, wide clip → landscape).
    private func detectVideoOrientation() {
        guard videoIsPortrait == nil else { return }
        let s = player.videoSize
        guard s.width > 0, s.height > 0 else { return }
        var portrait = s.height > s.width
        // Phone portrait clips are encoded landscape + a 90°/270° rotation flag;
        // videoSize reports the ENCODED (landscape) dimensions, so a rotated
        // track means the frame is actually displayed transposed. Without this,
        // a portrait video wrongly forces the player into landscape.
        let rotated = videoIsQuarterRotated()
        if let rotated {
            if rotated { portrait.toggle() }
        } else if !portrait, elapsedSeconds < 3 {
            // Landscape dimensions + unknown rotation is the ambiguous case (could
            // be a rotated-portrait clip). Network streams parse track metadata
            // lazily, so wait a beat for the rotation flag before committing —
            // otherwise a portrait remote video briefly reads as landscape and
            // locks there. Portrait dimensions are trusted immediately.
            return
        }
        videoIsPortrait = portrait
    }

    /// Whether the video track carries a 90°/270° rotation. Read from the media
    /// metadata without depending on an exact VLCKit constant name (it varies by
    /// build): any track key mentioning "orientation" whose value is a
    /// VLCMediaOrientation raw >= 4 is a quarter-turn. nil when unknown.
    private func videoIsQuarterRotated() -> Bool? {
        guard let tracks = player.media?.tracksInformation as? [[AnyHashable: Any]] else { return nil }
        for t in tracks {
            if let entry = t.first(where: {
                ($0.key as? String)?.lowercased().contains("orientation") == true
            }), let n = entry.value as? NSNumber {
                return n.intValue >= 4
            }
        }
        return nil
    }

    // MARK: audio boost

    func setAudioBoost(_ percent: Int) {
        audioBoost = max(100, min(200, percent))
        player.audio?.volume = Int32(audioBoost)
    }
    private func reapplyAudioBoost() {
        if audioBoost != 100 { player.audio?.volume = Int32(audioBoost) }
    }

    // MARK: preferred languages — best-effort match on the track name

    /// Auto-select the audio/subtitle track whose name contains the user's
    /// preferred language. Runs on first track load and when the preference
    /// changes mid-playback.
    func applyPreferredLanguages() {
        if let pa = UserDefaults.standard.string(forKey: "preferred_audio_language"), !pa.isEmpty,
           let t = audioTracks.first(where: { $0.name.range(of: pa, options: .caseInsensitive) != nil }) {
            selectAudio(t.id)
        }
        if let ps = UserDefaults.standard.string(forKey: "preferred_subtitle_language"), !ps.isEmpty,
           let t = subtitleTracks.first(where: { $0.name.range(of: ps, options: .caseInsensitive) != nil }) {
            selectSubtitle(t.id)
        }
    }

    // MARK: HLS quality

    func selectQuality(_ q: Quality) {
        currentQualityId = q.id
        playURLOverride = q.url
        reopenPreservingPosition()
    }

    /// Fetch + parse the HLS master (only for HLS) so a manual quality picker can
    /// appear. VLC only does adaptive internally, so we switch quality by
    /// re-opening with the chosen variant URL.
    private func loadQualities() {
        guard let item, item.contentType == "hls" || item.url.path.lowercased().hasSuffix(".m3u8")
        else { return }
        let url = item.url, headers = item.headers
        Task { [weak self] in
            let variants = await HLSVariants.fetch(url: url, headers: headers)
            guard variants.count > 1 else { return }
            await MainActor.run {
                guard let self else { return }
                self.qualities = [Quality.auto] + variants.map {
                    Quality(
                        id: "\($0.height)_\($0.bandwidth)",
                        label: $0.height > 0 ? "\($0.height)p" : "\($0.bandwidth / 1000) kbps",
                        url: $0.url
                    )
                }
            }
        }
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
            Task { @MainActor in self?.player.play(); self?.wantsPlayback = true }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause(); self?.wantsPlayback = false }; return .success
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
        // Backgrounding tears down VLC's video output; audio keeps going but the
        // surface returns black. Re-attach the drawable on foreground to rebuild it.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshVideoOutput() }
        }
    }

    /// Rebuild the video output after returning from the background, where VLC's
    /// vout is destroyed (black frame, audio-only). Reassigning the drawable
    /// forces a fresh vout; a zero-distance seek re-renders a frame immediately.
    private func refreshVideoOutput() {
        guard let v = drawableView else { return }
        player.drawable = nil
        player.drawable = v
        if player.isPlaying {
            let p = player.position
            player.position = p
        }
    }

    private func scheduleBufferWatchdog() {
        bufferWatchdog?.cancel()
        bufferWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            // Still stuck buffering and the user wants playback → nudge VLC.
            if self.buffering, self.wantsPlayback, !self.player.isPlaying {
                self.player.play()
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

        if !audioTracks.isEmpty || !subtitleTracks.isEmpty {
            tracksLoaded = true
            applyPreferredLanguages()
        }
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
            case .buffering, .opening:
                buffering = !player.isPlaying
                if buffering { scheduleBufferWatchdog() }
            case .playing:
                bufferWatchdog?.cancel()
                buffering = false; failure = nil
                loadTracksIfNeeded()
                reapplySync()
                reapplyAudioBoost()
                applyAspect()
                detectVideoOrientation()
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
            detectVideoOrientation()
            updateNowPlaying()

            // Throttle resume persistence to ~5s.
            if Date().timeIntervalSince(lastResumeSave) > 5 {
                lastResumeSave = Date(); saveResume()
            }
        }
    }
}
