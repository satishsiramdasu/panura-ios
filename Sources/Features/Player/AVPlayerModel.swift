import Foundation
import UIKit
import AVFoundation
import AVKit
import CoreImage
import MediaPlayer

/// A view whose backing layer IS the AVPlayerLayer, so the picture follows the
/// view's bounds through rotation and zoom with no layout code at all.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// AVPlayer behind the same control overlay VLC uses.
///
/// What it adds over VLC: the system's Picture in Picture, AirPlay, hardware
/// decoding with HDR, and a player Apple maintains. What it cannot do on its
/// own is the other half of the plan: containers and audio codecs AVPlayer does
/// not read (MKV, AVI, DTS…) arrive with the FFmpeg path, and so do audio delay
/// and boost, which AVPlayer offers no hook for on a stream. Until then those
/// controls are hidden rather than inert — see the `supports…` flags.
///
/// Subtitles arrive two ways. Those inside an HLS stream AVPlayer renders itself,
/// styled from Settings through text style rules. Files sniffed from the page —
/// SRT, WebVTT, ASS, TTML — are fetched and timed here and drawn by
/// `SubtitleOverlay`, where outline, font and the delay control all apply.
@MainActor
final class AVPlayerModel: NSObject, ObservableObject, PlayerEngine {
    static func makeEngine() -> AVPlayerModel { AVPlayerModel() }

    @Published var isPlaying = false
    @Published var position: Float = 0
    @Published var displayTitle = ""
    @Published var elapsed = "0:00"
    @Published var remaining = "-0:00"
    @Published var total = "0:00"
    @Published var buffering = true
    @Published var failure: String?
    @Published private(set) var resumeEntryRemoved = false
    @Published var rate: Float = 1.0

    @Published var audioTracks: [PlayerTrack] = []
    @Published var subtitleTracks: [PlayerTrack] = []
    @Published var currentAudioId: Int = -1
    @Published var currentSubtitleId: Int = -1

    @Published var aspect: PlayerAspectMode = .fit
    @Published var subtitleDelayMs: Int = 0
    @Published var audioDelayMs: Int = 0
    @Published var audioBoost: Int = 100
    @Published var sleepRemaining: Int?
    @Published var qualities: [PlayerQuality] = []
    @Published var currentQualityId: String = PlayerQuality.auto.id
    @Published var videoIsPortrait: Bool?
    @Published private(set) var isPictureInPictureActive = false

    /// The sidecar subtitle to draw now, or nil.
    @Published private(set) var overlaySubtitle: String?

    // Audio delay and boost arrive with the FFmpeg path.
    let supportsAudioDelay = false
    let supportsAudioBoost = false
    let supportsAirPlay = true
    /// Only while a sidecar track is on, because only those are timed here.
    /// Subtitles inside the stream are timed by AVPlayer, which has no offset.
    var supportsSubtitleDelay: Bool { currentSubtitleId >= Self.sidecarBase }
    var supportsPictureInPicture: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private let player = AVPlayer()
    private weak var videoView: PlayerLayerView?
    private var pictureInPicture: AVPictureInPictureController?

    private var item: MediaItem?
    /// Set for one rebuild, to send a stream through the relay that would
    /// otherwise have played directly.
    private var forceRelay = false
    /// How the current attempt was actually opened.
    private var playedThroughRelay = false
    /// One relay retry per item; a second would loop on a stream that is dead.
    private var relayRetryUsed = false

    private var pendingResumeSeconds: Double?
    private var resumeApplied = false
    private var lastResumeSave = Date.distantPast
    private var lastNowPlaying = Date.distantPast

    private var rateBeforeBoost: Float = 1.0
    private var sleepTask: Task<Void, Never>?
    private var thumbnailCaptured = false
    private var videoOutput: AVPlayerItemVideoOutput?

    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?

    /// Sidecar track ids start here, clear of the stream's own subtitle
    /// options, which are numbered from 0.
    static let sidecarBase = 1000
    private var sidecarTimeline: SubtitleTimeline?
    private var sidecarTask: Task<Void, Never>?
    private var subtitleObserver: Any?
    /// Paused on purpose — the button, a remote, the sleep timer. Anything else
    /// that stops playback (an audio interruption, a web page grabbing the
    /// session) is undone once it ends; a pause the user asked for never is.
    private var userPaused = false
    /// The HLS format check and the no-picture watch, per item.
    private var supportTask: Task<Void, Never>?
    private var pictureWatch: Task<Void, Never>?

    /// Raised when this player cannot play the video's format: HEVC in MPEG-TS
    /// found by `AppleHLSSupport`, or no picture ever appearing. Auto hands the
    /// video to VLC on it; with the Apple player forced, the user reads it.
    static let unsupportedMessage = "The Apple player can't play this video's format. Choose Auto or VLC in Settings → Playback."

    private var timeObserver: Any?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var remoteTargets: [(command: MPRemoteCommand, token: Any)] = []

    private var backgroundPlayEnabled: Bool {
        UserDefaults.standard.bool(forKey: "background_play")
    }

    private var resumeEnabled: Bool {
        UserDefaults.standard.object(forKey: "resume_playback") as? Bool ?? true
    }

    // MARK: lifecycle

    func makeVideoView() -> UIView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func start(item: MediaItem, into view: UIView) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        if let view = view as? PlayerLayerView {
            videoView = view
            view.playerLayer.player = player
            setUpPictureInPicture(view.playerLayer)
        }
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        observePlayer()
        setupRemoteCommands()
        observeLifecycle()
        load(item)
    }

    func play(item newItem: MediaItem) {
        saveResume()
        load(newItem)
    }

    /// Everything that belongs to one item, reset and opened. Shared by the
    /// first item and every next/previous.
    private func load(_ newItem: MediaItem) {
        item = newItem
        displayTitle = newItem.title
        videoIsPortrait = nil
        qualities = []; currentQualityId = PlayerQuality.auto.id
        audioTracks = []; subtitleTracks = []
        currentAudioId = -1; currentSubtitleId = -1
        subtitleDelayMs = 0; audioDelayMs = 0
        failure = nil; buffering = true
        pendingResumeSeconds = nil; resumeApplied = false
        relayRetryUsed = false; forceRelay = false
        thumbnailCaptured = false
        userPaused = false
        clearSidecar()
        // Offered at once: the page's subtitle files are known before the
        // stream's own options have loaded.
        subtitleTracks = Self.sidecarTracks(newItem)

        if resumeEnabled {
            let saved = UserDefaults.standard.double(forKey: Self.resumeKey(newItem.url))
            if saved > 15 { pendingResumeSeconds = saved }
        }
        // Surface it on Home right away — the user may leave before the first
        // position save, and an item that never appears can't be resumed from.
        BrowsingStore.shared.beginWatching(newItem)

        buildAndPlay()
        loadQualities()
        checkSupport(newItem)
        watchForPicture(newItem)
    }

    /// (Re)builds the player item for the current source and starts it.
    private func buildAndPlay() {
        guard let item else { return }

        // The relay has one job left here: content type. A CDN serving an
        // extensionless playlist as text/plain gives AVPlayer nothing to
        // recognise it by; the relay re-serves it as application/vnd.apple.mpegurl.
        // It is also the retry after a direct failure — see `retryThroughRelay`.
        // Headers do NOT need it: AVURLAsset sends them itself, below.
        let path = item.url.path.lowercased()
        let needsTypeRelay = !item.isLocal && item.contentType == "hls" && !path.hasSuffix(".m3u8")
        let relay = !item.isLocal && (needsTypeRelay || forceRelay)
        let playURL = relay
            ? StreamProxy.shared.proxied(url: item.url, headers: item.headers, playlistHint: needsTypeRelay)
            : item.url
        playedThroughRelay = relay

        var options: [String: Any] = [:]
        if !relay, !item.headers.isEmpty {
            // Every captured header — Referer, Origin, User-Agent, Cookie — on
            // every request the asset makes: playlist, segments, keys. The key
            // is not in Apple's public headers, but it is the only way to give
            // AVURLAsset request headers without routing the whole stream
            // through the local relay, and iOS has honoured it for a decade.
            // The relay would work too, but it buffers each response in full,
            // which is fine for a 4 MB segment and ruinous for a 2 GB MP4.
            options["AVURLAssetHTTPHeaderFieldsKey"] = item.headers
        }
        let asset = AVURLAsset(url: playURL, options: options)
        let playerItem = AVPlayerItem(asset: asset)

        attachVideoOutput(to: playerItem)
        applySubtitleStyle(to: playerItem)
        applyQualityCap(to: playerItem)
        observeItem(playerItem)
        player.replaceCurrentItem(with: playerItem)

        let defaultSpeed = UserDefaults.standard.object(forKey: "default_playback_speed") as? Double ?? 1.0
        rate = Float(defaultSpeed)
        // defaultRate is what play() uses, so a speed survives pause and resume
        // instead of snapping back to 1× the way `rate` alone would.
        player.defaultRate = rate
        player.play()

        loadMediaSelections(asset: asset, playerItem: playerItem)
    }

    /// Re-opens through the relay after a direct attempt failed. False when
    /// there is nothing left to try, which is the caller's cue to report it.
    ///
    /// Never for a progressive file: the relay reads each response whole
    /// before answering, so a feature-length MP4 would have to download
    /// completely before a single frame played.
    @discardableResult
    private func retryThroughRelay() -> Bool {
        guard let item, !item.isLocal, !relayRetryUsed, !playedThroughRelay,
              !Self.isProgressive(item) else { return false }
        relayRetryUsed = true
        forceRelay = true
        buffering = true
        let at = elapsedSeconds
        if at > 2 { pendingResumeSeconds = at }
        resumeApplied = false
        buildAndPlay()
        return true
    }

    private static func isProgressive(_ item: MediaItem) -> Bool {
        if item.contentType?.lowercased() == "mp4" { return true }
        let path = item.url.path.lowercased()
        return [".mp4", ".m4v", ".mov", ".mkv", ".webm"].contains { path.hasSuffix($0) }
    }

    func stop() {
        sleepTask?.cancel()
        sleepTask = nil
        saveResume()
        pictureInPicture?.stopPictureInPicture()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let subtitleObserver { player.removeTimeObserver(subtitleObserver) }
        subtitleObserver = nil
        sidecarTask?.cancel()
        supportTask?.cancel()
        pictureWatch?.cancel()
        playerObservations.removeAll()
        itemObservations.removeAll()
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
        itemNotifications.removeAll()
        for token in lifecycleObservers { NotificationCenter.default.removeObserver(token) }
        lifecycleObservers.removeAll()
        removeRemoteCommands()
        player.replaceCurrentItem(with: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        ScreenBrightness.restore()
    }

    // MARK: observation

    private func observePlayer() {
        guard timeObserver == nil else { return }
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
                let status = p.timeControlStatus
                Task { @MainActor in self?.timeControlChanged(status) }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Finer than the clock: a subtitle a quarter-second late reads as out of
        // sync, and a lookup is a binary search.
        subtitleObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateOverlay() }
        }
    }

    private func observeItem(_ playerItem: AVPlayerItem) {
        itemObservations = [
            playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
                Task { @MainActor in self?.itemStatusChanged(observed) }
            },
            playerItem.observe(\.presentationSize, options: [.new]) { [weak self] observed, _ in
                let size = observed.presentationSize
                Task { @MainActor in self?.detectVideoOrientation(size) }
            },
        ]
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
        itemNotifications = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reachedEnd() }
            },
        ]
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            isPlaying = true
            buffering = false
        case .waitingToPlayAtSpecifiedRate:
            // The user wants playback and is waiting on the network: the pause
            // glyph is right, and the loading ring replaces it meanwhile.
            isPlaying = true
            buffering = true
        case .paused:
            isPlaying = false
            buffering = false
        @unknown default:
            break
        }
        updateNowPlaying(force: true)
    }

    private func itemStatusChanged(_ observed: AVPlayerItem) {
        guard observed === player.currentItem else { return }
        switch observed.status {
        case .readyToPlay:
            failure = nil
            applyAspect()
            // play() went out before the item was ready, and something may have
            // stopped it in between — most often the page's own video under
            // the player. Ready is the moment to insist.
            if !userPaused, player.rate == 0 { player.play() }
            // Readiness is when AVPlayer applies its own selection criteria,
            // which can quietly replace the subtitle the sheet shows as on.
            syncSubtitleSelection()
            applyResumeIfPending()
            updateNowPlaying(force: true)
        case .failed:
            // One more attempt, through the relay — a genuinely different
            // request: the playlist re-served with a playlist MIME type, every
            // segment under an extensionless URL with its real Content-Type,
            // decoy image headers stripped on the way through.
            if retryThroughRelay() { return }
            buffering = false
            isPlaying = false
            failure = "This stream could not be opened."
            dropResumeIfSourceIsGone()
        default:
            break
        }
    }

    private func tick() {
        guard player.currentItem != nil else { return }
        let elapsedS = elapsedSeconds
        let durationS = totalSeconds
        position = durationS > 0 ? Float(elapsedS / durationS) : 0
        elapsed = PlayerClock.format(elapsedS)
        remaining = "-" + PlayerClock.format(max(0, durationS - elapsedS))
        total = PlayerClock.format(durationS)
        applyResumeIfPending()
        updateNowPlaying()
        if Date().timeIntervalSince(lastResumeSave) > 5 {
            lastResumeSave = Date()
            saveResume()
        }
    }

    /// Beside the direct start, never before it: a supported stream pays nothing.
    private func checkSupport(_ checked: MediaItem) {
        supportTask?.cancel()
        supportTask = Task { [weak self] in
            guard await AppleHLSSupport.isUnsupported(checked) else { return }
            guard let self, !Task.isCancelled, self.item?.id == checked.id else { return }
            self.raiseUnsupported()
        }
    }

    /// The backstop for what the format check cannot see. AVPlayer given video
    /// it cannot decode rarely says so: it plays the audio over a black screen,
    /// or never gets past loading. Three seconds of playback without a picture,
    /// or twenty seconds of trying without one, count as unsupported. A pause
    /// before the first picture restarts the clock — nothing is being tried.
    /// Runs on its own clock because the time observer does not fire while
    /// nothing plays.
    private func watchForPicture(_ watched: MediaItem) {
        pictureWatch?.cancel()
        pictureWatch = Task { [weak self] in
            var started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.item?.id == watched.id, self.failure == nil else { return }
                guard let current = self.player.currentItem else { continue }
                if current.presentationSize != .zero { return }
                if self.userPaused {
                    started = Date()
                    continue
                }
                let playedWithoutPicture = current.status == .readyToPlay && self.elapsedSeconds > 3
                if playedWithoutPicture || Date().timeIntervalSince(started) > 20 {
                    self.raiseUnsupported()
                    return
                }
            }
        }
    }

    private func raiseUnsupported() {
        guard failure == nil else { return }
        pictureWatch?.cancel()
        player.pause()
        buffering = false
        isPlaying = false
        failure = Self.unsupportedMessage
    }

    private func reachedEnd() {
        isPlaying = false
        saveResume()
        updateNowPlaying(force: true)
    }

    // MARK: transport

    var totalSeconds: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite && d > 0 ? d : 0
    }

    var elapsedSeconds: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    var skipInterval: Int {
        let v = UserDefaults.standard.integer(forKey: "skip_interval")
        return v > 0 ? v : 10
    }

    func togglePlay() {
        if player.timeControlStatus == .paused { resume() } else { pause() }
    }

    private func resume() {
        // At the end, play means from the top; AVPlayer otherwise sits on the
        // last frame and does nothing.
        if totalSeconds > 0, elapsedSeconds >= totalSeconds - 0.5 {
            player.seek(to: .zero)
        }
        userPaused = false
        player.play()
    }

    private func pause() {
        userPaused = true
        player.pause()
    }

    /// iOS pauses AVPlayer for a call, Siri, or another player taking the audio
    /// session. When that ends with permission to resume, carry on — unless
    /// the user had paused anyway.
    private func audioInterruption(began: Bool, shouldResume: Bool) {
        guard !began, shouldResume, !userPaused, player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func skipForward() { skip(skipInterval) }
    func skipBackward() { skip(-skipInterval) }

    private func skip(_ seconds: Int) {
        var target = max(0, elapsedSeconds + Double(seconds))
        if totalSeconds > 0 { target = min(target, totalSeconds) }
        seek(seconds: target)
    }

    func seek(to fraction: Float) {
        guard totalSeconds > 0 else { return }
        seek(seconds: Double(max(0, min(1, fraction))) * totalSeconds)
    }

    private func seek(seconds: Double) {
        // Shown at once, so a scrub does not snap back to the old position for
        // the moment the seek takes.
        if totalSeconds > 0 { position = Float(seconds / totalSeconds) }
        elapsed = PlayerClock.format(seconds)
        // Frame-exact for a local file, where it is cheap. A stream is allowed
        // half a second either way: exact means decoding forward from the last
        // keyframe over the network, which turns a scrub into a wait.
        let local = item?.isLocal == true
        let tolerance = local ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if player.timeControlStatus != .paused { player.rate = r }
    }

    func beginSpeedBoost() { rateBeforeBoost = rate; setRate(2.0) }
    func endSpeedBoost() { setRate(rateBeforeBoost) }

    // MARK: tracks

    private func loadMediaSelections(asset: AVURLAsset, playerItem: AVPlayerItem) {
        Task { [weak self] in
            let audible: AVMediaSelectionGroup? = (try? await asset.loadMediaSelectionGroup(for: .audible)) ?? nil
            let legible: AVMediaSelectionGroup? = (try? await asset.loadMediaSelectionGroup(for: .legible)) ?? nil
            guard let self, playerItem === self.player.currentItem else { return }
            self.audibleGroup = audible
            self.legibleGroup = legible
            self.audioTracks = audible.map(Self.tracks) ?? []
            self.subtitleTracks = (legible.map(Self.tracks) ?? []) + Self.sidecarTracks(self.item)
            self.currentAudioId = Self.selectedIndex(in: audible, of: playerItem)
            // A sidecar picked while the options loaded stays picked.
            if self.currentSubtitleId < Self.sidecarBase {
                self.currentSubtitleId = Self.selectedIndex(in: legible, of: playerItem)
            }
            self.syncSubtitleSelection()
            self.applyPreferredLanguages()
        }
    }

    private static func tracks(_ group: AVMediaSelectionGroup) -> [PlayerTrack] {
        group.options.enumerated().map { PlayerTrack(id: $0.offset, name: $0.element.displayName) }
    }

    private static func selectedIndex(in group: AVMediaSelectionGroup?, of playerItem: AVPlayerItem) -> Int {
        guard let group,
              let selected = playerItem.currentMediaSelection.selectedMediaOption(in: group),
              let index = group.options.firstIndex(of: selected)
        else { return -1 }
        return index
    }

    func selectAudio(_ id: Int) {
        guard let group = audibleGroup, group.options.indices.contains(id) else { return }
        player.currentItem?.select(group.options[id], in: group)
        currentAudioId = id
    }

    func selectSubtitle(_ id: Int) {
        if id >= Self.sidecarBase {
            let index = id - Self.sidecarBase
            guard let item, item.subtitles.indices.contains(index) else { return }
            // One subtitle at a time: the stream's own goes off.
            if let group = legibleGroup { player.currentItem?.select(nil, in: group) }
            currentSubtitleId = id
            loadSidecar(item.subtitles[index], headers: item.headers, id: id)
            return
        }
        clearSidecar()
        guard let group = legibleGroup else { currentSubtitleId = -1; return }
        if id < 0 {
            player.currentItem?.select(nil, in: group)
            currentSubtitleId = -1
            return
        }
        guard group.options.indices.contains(id) else { return }
        player.currentItem?.select(group.options[id], in: group)
        currentSubtitleId = id
    }

    /// Makes the selection the sheet shows the one AVPlayer actually renders.
    ///
    /// A stream's default subtitle is reported as selected from the start, but
    /// while it is only AVPlayer's automatic pick it is often not drawn — the
    /// sheet says on, the screen shows nothing, and turning it off and on (an
    /// explicit select) fixes it. So it is selected explicitly here, the same
    /// call that toggle makes. With a sidecar on, the stream's own stays off.
    private func syncSubtitleSelection() {
        guard let group = legibleGroup, let playerItem = player.currentItem else { return }
        if currentSubtitleId >= Self.sidecarBase {
            playerItem.select(nil, in: group)
        } else if group.options.indices.contains(currentSubtitleId) {
            playerItem.select(group.options[currentSubtitleId], in: group)
        }
    }

    /// Best-effort match on the track name, as VLC does.
    func applyPreferredLanguages() {
        let defaults = UserDefaults.standard
        if let pa = defaults.string(forKey: "preferred_audio_language"), !pa.isEmpty,
           let t = audioTracks.first(where: { $0.name.range(of: pa, options: .caseInsensitive) != nil }) {
            selectAudio(t.id)
        }
        if let ps = defaults.string(forKey: "preferred_subtitle_language"), !ps.isEmpty,
           let t = subtitleTracks.first(where: { $0.name.range(of: ps, options: .caseInsensitive) != nil }) {
            selectSubtitle(t.id)
        }
    }

    // MARK: subtitles

    func adjustSubtitleDelay(_ deltaMs: Int) {
        subtitleDelayMs += deltaMs
        updateOverlay()
    }

    private static func sidecarTracks(_ item: MediaItem?) -> [PlayerTrack] {
        (item?.subtitles ?? []).enumerated().map {
            PlayerTrack(id: sidecarBase + $0.offset, name: $0.element.displayName)
        }
    }

    /// Fetches a page's subtitle file with the page's own headers — the host
    /// that gates the stream usually gates its subtitles too — and parses it off
    /// the main actor. A later pick cancels an earlier one still downloading.
    private func loadSidecar(_ track: SubtitleTrack, headers: [String: String], id: Int) {
        sidecarTask?.cancel()
        sidecarTimeline = nil
        overlaySubtitle = nil
        let encoding = UserDefaults.standard.string(forKey: "subtitle_encoding") ?? ""
        sidecarTask = Task { [weak self] in
            var request = URLRequest(url: track.url)
            request.timeoutInterval = 15
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            // Three tries. The first fetch races the stream's own opening
            // requests and a gated host sometimes drops it; with no retry the
            // track stayed selected and silent until it was picked again.
            for attempt in 0..<3 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
                guard !Task.isCancelled else { return }
                guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
                let cues = await Task.detached { SubtitleParser.cues(from: data, encoding: encoding) }.value
                if cues.isEmpty { continue }
                guard let self, !Task.isCancelled, self.currentSubtitleId == id else { return }
                self.sidecarTimeline = SubtitleTimeline(cues: cues)
                self.updateOverlay()
                return
            }
        }
    }

    private func clearSidecar() {
        sidecarTask?.cancel()
        sidecarTask = nil
        sidecarTimeline = nil
        overlaySubtitle = nil
    }

    /// Positive delay shows subtitles later, as VLC's does.
    private func updateOverlay() {
        guard let timeline = sidecarTimeline else {
            if overlaySubtitle != nil { overlaySubtitle = nil }
            return
        }
        let text = timeline.text(at: elapsedSeconds - Double(subtitleDelayMs) / 1000)
        if text != overlaySubtitle { overlaySubtitle = text }
    }

    func subtitleStyleChanged() {
        if let current = player.currentItem { applySubtitleStyle(to: current) }
    }

    /// The Subtitles settings, as text style rules for subtitles the stream
    /// itself carries. Applied in place — no reopen, unlike VLC.
    ///
    /// Size maps onto the same three steps: Medium (24) is AVPlayer's default
    /// size, Small and Large scale from it. Outline, encoding and embedded
    /// styles have no equivalent for stream subtitles and wait for the overlay.
    private func applySubtitleStyle(to playerItem: AVPlayerItem) {
        let defaults = UserDefaults.standard
        let size = defaults.object(forKey: "subtitle_size") as? Int ?? 24
        let color = defaults.object(forKey: "subtitle_color") as? Int ?? 0xFFFFFF
        let background = defaults.bool(forKey: "subtitle_background")
        let bold = defaults.bool(forKey: "subtitle_bold")
        let font = defaults.string(forKey: "subtitle_font") ?? ""

        let red = Double((color >> 16) & 0xFF) / 255
        let green = Double((color >> 8) & 0xFF) / 255
        let blue = Double(color & 0xFF) / 255

        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: Double(size) / 24 * 100,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1.0, red, green, blue],
        ]
        if bold { attributes[kCMTextMarkupAttribute_BoldStyle as String] = true }
        if !font.isEmpty { attributes[kCMTextMarkupAttribute_FontFamilyName as String] = font }
        if background {
            attributes[kCMTextMarkupAttribute_BackgroundColorARGB as String] = [1.0, 0.0, 0.0, 0.0]
        }
        playerItem.textStyleRules = AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
    }

    // MARK: audio (arrives with FFmpeg)

    func adjustAudioDelay(_ deltaMs: Int) { audioDelayMs += deltaMs }
    func setAudioBoost(_ percent: Int) { audioBoost = max(100, min(200, percent)) }

    // MARK: picture

    func cycleAspect() {
        let all = PlayerAspectMode.allCases
        let i = all.firstIndex(of: aspect) ?? 0
        aspect = all[(i + 1) % all.count]
        applyAspect()
    }

    private func applyAspect() {
        guard let layer = videoView?.playerLayer else { return }
        switch aspect {
        case .fit: layer.videoGravity = .resizeAspect
        case .fill: layer.videoGravity = .resizeAspectFill
        case .stretch: layer.videoGravity = .resize
        }
    }

    /// presentationSize already has the track's rotation applied, so a phone
    /// clip recorded upright reads as portrait — the case VLC needed a metadata
    /// probe for.
    private func detectVideoOrientation(_ size: CGSize) {
        guard videoIsPortrait == nil, size.width > 0, size.height > 0 else { return }
        videoIsPortrait = size.height > size.width
    }

    // MARK: quality

    /// Stays on the master playlist and caps the bitrate at the chosen
    /// rendition, instead of reopening the variant URL as VLC must. No rebuffer,
    /// no lost audio renditions, and Auto is simply the cap removed.
    func selectQuality(_ q: PlayerQuality) {
        currentQualityId = q.id
        if let current = player.currentItem { applyQualityCap(to: current) }
    }

    private func applyQualityCap(to playerItem: AVPlayerItem) {
        guard let q = qualities.first(where: { $0.id == currentQualityId }), q.url != nil else {
            playerItem.preferredPeakBitRate = 0
            playerItem.preferredMaximumResolution = .zero
            return
        }
        // A little headroom: the cap is inclusive in practice, but an exact
        // match against an advertised average is not a thing to rely on.
        playerItem.preferredPeakBitRate = q.bandwidth > 0 ? Double(q.bandwidth) + 1_000 : 0
        playerItem.preferredMaximumResolution = q.height > 0
            ? CGSize(width: 10_000, height: q.height)
            : .zero
    }

    private func loadQualities() {
        guard let item, !item.isLocal else { return }
        let type = item.contentType?.lowercased()
        guard type != "mp4", type != "dash" else { return }
        let path = item.url.path.lowercased()
        guard !path.hasSuffix(".mp4"), !path.hasSuffix(".mkv"),
              !path.hasSuffix(".webm"), !path.hasSuffix(".mpd")
        else { return }

        let url = item.url, headers = item.headers
        Task { [weak self] in
            let variants = await HLSVariants.fetch(url: url, headers: headers)
            guard variants.count > 1, let self, self.item?.url == url else { return }
            self.qualities = [PlayerQuality.auto] + variants.map {
                PlayerQuality(
                    id: "\($0.height)_\($0.bandwidth)",
                    label: $0.height > 0 ? "\($0.height)p" : "\($0.bandwidth / 1000) kbps",
                    url: $0.url,
                    bandwidth: $0.bandwidth,
                    height: $0.height
                )
            }
        }
    }

    // MARK: Picture in Picture

    private func setUpPictureInPicture(_ layer: AVPlayerLayer) {
        guard pictureInPicture == nil, AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.delegate = self
        // Swiping home mid-video floats it, as every video app on iOS does.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPicture = controller
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            pictureInPicture.startPictureInPicture()
        }
    }

    // MARK: sleep timer

    /// Counts down and pauses — pause, not stop, so waking to it keeps your place.
    func startSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        sleepRemaining = minutes * 60
        sleepTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let self, let left = self.sleepRemaining else { return }
                if left <= 1 {
                    self.sleepRemaining = nil
                    if self.isPlaying { self.pause() }
                    return
                }
                self.sleepRemaining = left - 1
            }
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepRemaining = nil
    }

    var sleepLabel: String? {
        guard let left = sleepRemaining else { return nil }
        return left >= 60 ? "\(left / 60)m" : "\(left)s"
    }

    // MARK: lock screen / Control Center

    private func updateNowPlaying(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastNowPlaying) > 1 else { return }
        lastNowPlaying = Date()
        let title = item?.title ?? ""
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Panura" : title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? Double(player.rate) : 0,
        ]
        if totalSeconds > 0 { info[MPMediaItemPropertyPlaybackDuration] = totalSeconds }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Targets are kept and removed on stop. Added and never removed, every
    /// player opened would stack another handler on the shared command centre.
    private func setupRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]

        remoteTargets.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }))
        remoteTargets.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }))
        remoteTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }))
        remoteTargets.append((center.skipForwardCommand, center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }
            return .success
        }))
        remoteTargets.append((center.skipBackwardCommand, center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }
            return .success
        }))
        remoteTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = e.positionTime
            Task { @MainActor in self?.seek(seconds: target) }
            return .success
        }))
    }

    private func removeRemoteCommands() {
        for target in remoteTargets { target.command.removeTarget(target.token) }
        remoteTargets.removeAll()
    }

    // MARK: background behaviour

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enteredBackground() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.enteringForeground() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            guard let type else { return }
            let began = type == .began
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor in self?.audioInterruption(began: began, shouldResume: shouldResume) }
        })
    }

    private func enteredBackground() {
        // Picture in Picture owns the layer while it runs.
        if isPictureInPictureActive || pictureInPicture?.isPictureInPictureActive == true { return }
        guard backgroundPlayEnabled else { pause(); return }
        // iOS pauses a player that is still attached to a layer when the app
        // leaves the screen. Detaching the layer is what lets the audio go on.
        videoView?.playerLayer.player = nil
    }

    private func enteringForeground() {
        videoView?.playerLayer.player = player
    }

    // MARK: resume

    private static func resumeKey(_ url: URL) -> String {
        ResumePosition.key(url.absoluteString)
    }

    private func applyResumeIfPending() {
        let total = totalSeconds
        guard !resumeApplied, let target = pendingResumeSeconds, total > 0,
              player.currentItem?.status == .readyToPlay else { return }
        resumeApplied = true
        // Never resume into the last 15s.
        guard target < total - 15 else { return }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func saveResume() {
        // A dead source has already had its row deleted; saving on the way out
        // would re-add exactly the entry that was just dropped.
        guard !resumeEntryRemoved, resumeEnabled, let item else { return }
        let e = elapsedSeconds, total = totalSeconds
        if total > 0, e > 15, e < total - 15 {
            UserDefaults.standard.set(e, forKey: Self.resumeKey(item.url))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.resumeKey(item.url))
        }
        BrowsingStore.shared.updateWatching(url: item.url, position: e, duration: total)
        captureThumbnailIfNeeded()
    }

    /// Only when the source is PROVEN gone — see VLCPlayerModel's twin for why
    /// a timeout must never count.
    private func dropResumeIfSourceIsGone() {
        guard let item, !resumeEntryRemoved else { return }
        if item.isLocal {
            guard !FileManager.default.fileExists(atPath: item.url.path) else { return }
            forgetResume(item)
            return
        }
        Task { [weak self] in
            let outcome = await StreamProbe.probe(url: item.url, headers: item.headers, ruleMatched: false)
            guard !outcome.active else { return }
            self?.forgetResume(item)
        }
    }

    private func forgetResume(_ item: MediaItem) {
        UserDefaults.standard.removeObject(forKey: Self.resumeKey(item.url))
        BrowsingStore.shared.removeWatching(url: item.url.absoluteString)
        resumeEntryRemoved = true
    }

    // MARK: thumbnail

    private func attachVideoOutput(to playerItem: AVPlayerItem) {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        playerItem.add(output)
        videoOutput = output
    }

    /// One frame per played item for the Continue Watching card, taken from the
    /// decoder's own output — a snapshot of the layer comes back black.
    private func captureThumbnailIfNeeded() {
        guard !thumbnailCaptured, let item, isPlaying, elapsedSeconds > 15,
              let output = videoOutput else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        thumbnailCaptured = true

        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 280 / max(1, image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
        else { return }

        let path = ResumeThumbnails.path(for: item.url)
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return }
        BrowsingStore.shared.setThumbnail(url: item.url, path: path)
    }
}

extension AVPlayerModel: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isPictureInPictureActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isPictureInPictureActive = false }
    }

    /// The player screen is still presented underneath, so there is nothing to
    /// rebuild: returning from PiP lands back on it.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
