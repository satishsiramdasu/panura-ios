import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import AVKit
import VLCKit

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
    /// True once a dead source has cost this item its Continue Watching entry —
    /// the failure message says so, rather than leaving it a silent deletion.
    @Published private(set) var resumeEntryRemoved = false
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

    /// Seconds left on the sleep timer, nil when none is set. Android has the
    /// same control, and it is the one player feature that is only ever wanted
    /// at the moment you are least likely to still be awake to use it.
    @Published var sleepRemaining: Int?

    /// HLS quality variants — populated only when the master playlist lists more
    /// than one. Empty otherwise, which is what hides the Quality button.
    @Published var qualities: [Quality] = []
    @Published var currentQualityId: String = Quality.auto.id

    /// nil until the real video dimensions arrive; then true for a portrait video.
    /// The view auto-rotates to match on change.
    @Published var videoIsPortrait: Bool?

    /// Shared with AVPlayerModel — defined in PlayerEngine.swift.
    typealias Track = PlayerTrack
    typealias Quality = PlayerQuality
    typealias AspectMode = PlayerAspectMode

    let player = VLCMediaPlayer()
    /// The player's video view, which libVLC's own output view sits inside.
    private(set) weak var drawableView: UIView?
    /// What libVLC is actually handed as its drawable — see `VLCVideoDrawable`.
    private var videoDrawable: VLCVideoDrawable?

    /// VLCKit 4's PiP controller, once the video output can float. Held weakly,
    /// as VLC for iOS does: the video output owns it and ends it with itself.
    private weak var pipController: VLCPictureInPictureWindowControlling?
    @Published private(set) var pipAvailable = false
    @Published private(set) var isPictureInPictureActive = false

    /// Length in milliseconds as libVLC last reported it. A stream often has no
    /// length when it opens, so this follows the player's length events.
    private var lengthMs: Int64 = 0
    /// Length from the HLS playlist itself, when it is a finished one. Per item:
    /// a quality switch reopens the same title, so it survives that.
    private var playlistDurationMs: Int = 0

    private var tracksLoaded = false
    private var item: MediaItem?
    private var playURLOverride: URL?     // a specific HLS variant; nil = master / Auto
    /// Set for one rebuild, to send a stream through the relay that the rules
    /// would otherwise have played directly.
    private var forceRelay = false
    /// How the current attempt was actually opened.
    private var playedThroughRelay = false
    /// One relay retry per item; a second would loop on a stream that is simply
    /// dead.
    private var relayRetryUsed = false
    private var observersAdded = false

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
        let drawable = VLCVideoDrawable(container: view, player: player)
        drawable.onPictureInPictureReady = { [weak self] controller in
            Task { @MainActor in self?.pictureInPictureReady(controller) }
        }
        drawable.onPictureInPictureChanged = { [weak self] started in
            Task { @MainActor in
                guard let self else { return }
                self.isPictureInPictureActive = started
                // VLCKit reports this after PiP has started, not before, so
                // the screen can come down here — see the note on
                // `beginPictureInPicture`, which the Apple player learnt the
                // hard way.
                if started {
                    PlaybackSession.shared.beginPictureInPicture()
                } else {
                    self.pictureInPictureStopped()
                }
            }
        }
        videoDrawable = drawable
        // Before the first play(): the video output checks the drawable for PiP
        // support when it is created, not afterwards.
        player.drawable = drawable
        player.delegate = self

        if resumeEnabled {
            let saved = UserDefaults.standard.double(forKey: Self.resumeKey(item.url))
            if saved > 15 { pendingResumeSeconds = saved }
        }
        // Surface it on Home right away — the user may leave before the first
        // position save, and an item that never appears can't be resumed from.
        BrowsingStore.shared.beginWatching(item)
        thumbnailCaptured = false
        playlistDurationMs = 0
        // A fresh item gets a fresh relay-retry budget; the flags are per item,
        // not per player.
        relayRetryUsed = false; forceRelay = false

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

        // A retry after a direct failure goes through the relay whatever the
        // rules above say — see `retryThroughRelay`.
        let relay = needsHeaderRelay || needsTypeRelay || forceRelay
        let playURL = relay
            ? StreamProxy.shared.proxied(
                url: sourceURL,
                headers: item.headers,
                playlistHint: needsTypeRelay || forceRelay
              )
            : sourceURL
        playedThroughRelay = relay

        guard let media = VLCMedia(url: playURL) else {
            buffering = false
            failure = "This stream could not be opened."
            return
        }
        lengthMs = 0
        applyHeaders(item.headers, to: media)     // belt-and-braces for the direct path
        applySubtitleStyle(to: media)
        player.media = media
        player.play()
        wantsPlayback = true

        // After play(): libVLC resets the rate when it opens new media, so a
        // rate set before this call is thrown away.
        let defaultSpeed = UserDefaults.standard.object(forKey: "default_playback_speed") as? Double ?? 1.0
        if defaultSpeed != 1.0 { setRate(Float(defaultSpeed)) }

        // Sidecar subtitles sniffed from the page — the stream itself usually
        // carries none, so without these there are no captions at all.
        for track in item.subtitles {
            _ = player.addPlaybackSlave(track.url, type: .subtitle, enforce: false)
        }

        tracksLoaded = false
        preferredLanguagesApplied = false
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
        let defaults = UserDefaults.standard
        let size = defaults.object(forKey: "subtitle_size") as? Int ?? 24
        let color = defaults.object(forKey: "subtitle_color") as? Int ?? 0xFFFFFF
        let background = defaults.bool(forKey: "subtitle_background")   // default off
        let bold = defaults.bool(forKey: "subtitle_bold")               // default off
        let outline = defaults.object(forKey: "subtitle_outline") as? Int ?? 4
        let font = defaults.string(forKey: "subtitle_font") ?? ""
        let encoding = defaults.string(forKey: "subtitle_encoding") ?? ""
        // Default ON: a subtitle file that carries its own styling usually
        // carries it for a reason — positioning for signs, colours per speaker.
        let embedded = defaults.object(forKey: "subtitle_embedded_styles") as? Bool ?? true

        media.addOption(":freetype-fontsize=\(size)")
        media.addOption(":freetype-color=\(color)")
        // A soft outline keeps white text legible over bright frames. At 0 the
        // renderer draws none, which is what "None" in Settings means.
        media.addOption(":freetype-outline-thickness=\(outline)")
        media.addOption(bold ? ":freetype-bold" : ":no-freetype-bold")
        if !font.isEmpty {
            media.addOption(":freetype-font=\(font)")
        }
        if !encoding.isEmpty {
            // Auto-detection handles UTF-8 and little else; a Windows-1256 Arabic
            // .srt renders as mojibake until it is told what it is.
            media.addOption(":subsdec-encoding=\(encoding)")
        }
        // `subsdec-formatted` is what honours ASS/SSA styling. Off, every line
        // is drawn in the style set above — which is the point of turning it off.
        media.addOption(embedded ? ":subsdec-formatted" : ":no-subsdec-formatted")
        if background {
            // Opaque black box behind the glyphs for readability.
            media.addOption(":freetype-background-opacity=255")
            media.addOption(":freetype-background-color=0")
        }
    }

    /// Re-opens through the relay after a direct attempt failed. Returns false
    /// when there is nothing left to try — already relayed, already retried, or
    /// no item at all — which is the caller's cue to report the failure.
    @discardableResult
    private func retryThroughRelay() -> Bool {
        guard item != nil, !relayRetryUsed, !playedThroughRelay else { return false }
        relayRetryUsed = true
        forceRelay = true
        buffering = true
        // Keep the playhead: a stream that fails ten minutes in should not
        // restart from the beginning just because the transport changed.
        reopenPreservingPosition()
        return true
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
        preferredLanguagesApplied = false
        playlistDurationMs = 0
        pendingResumeSeconds = nil; resumeApplied = false
        relayRetryUsed = false; forceRelay = false
        if resumeEnabled {
            let saved = UserDefaults.standard.double(forKey: Self.resumeKey(newItem.url))
            if saved > 15 { pendingResumeSeconds = saved }
        }
        // A quality switch carries a different URL, so it becomes its own resume
        // entry and needs its own frame.
        BrowsingStore.shared.beginWatching(newItem)
        thumbnailCaptured = false
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
    func skipForward()  { skip(skipInterval) }
    func skipBackward() { skip(-skipInterval) }
    /// One relative seek. libVLC 4 takes the offset in milliseconds.
    func skip(_ seconds: Int) {
        player.jump(withOffset: Int32(seconds * 1000))
    }

    func seek(to fraction: Float) {
        let clamped = max(0, min(1, fraction))
        // By time against the corrected length: libVLC's position is a fraction
        // of its OWN length, which is the value that can be a day too long.
        let total = durationMs
        if total > 0 {
            player.time = VLCTime(int: Int32(clamping: Int(Double(clamped) * Double(total))))
        } else {
            player.position = Double(clamped)
        }
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
        if isPictureInPictureActive { pipController?.stopPictureInPicture() }
        bufferWatchdog?.cancel()
        sleepTask?.cancel()
        sleepTask = nil
        saveResume()
        player.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        ScreenBrightness.restore()
    }

    /// Ids are positions in libVLC's track lists; -1 turns the kind off.
    func selectAudio(_ id: Int) {
        let tracks = player.audioTracks
        if tracks.indices.contains(id) {
            tracks[id].isSelectedExclusively = true
            currentAudioId = id
        } else {
            player.deselectAllAudioTracks()
            currentAudioId = -1
        }
    }
    func selectSubtitle(_ id: Int) {
        let tracks = player.textTracks
        if tracks.indices.contains(id) {
            tracks[id].isSelectedExclusively = true
            currentSubtitleId = id
        } else {
            player.deselectAllTextTracks()
            currentSubtitleId = -1
        }
    }

    // MARK: aspect / zoom

    func cycleAspect() {
        let all = AspectMode.allCases
        let i = all.firstIndex(of: aspect) ?? 0
        aspect = all[(i + 1) % all.count]
        applyAspect()
    }

    /// libVLC 4 has fit modes of its own, so Fill no longer fakes a crop from
    /// the view's pixel size. Stretch is still a forced aspect ratio: the
    /// view's, which the fitted picture then fills exactly.
    private func applyAspect() {
        player.scaleFactor = 0
        switch aspect {
        case .fit:
            player.videoAspectRatio = nil
            player.videoFitMode = .smaller
        case .fill:
            player.videoAspectRatio = nil
            player.videoFitMode = .larger
        case .stretch:
            let size = drawableView?.bounds.size ?? UIScreen.main.bounds.size
            let w = max(1, Int(size.width.rounded()))
            let h = max(1, Int(size.height.rounded()))
            player.videoFitMode = .smaller
            player.videoAspectRatio = "\(w):\(h)"
        }
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

    /// Whether the video track carries a 90°/270° rotation: the transposed
    /// VLCMediaOrientation cases are the last four. nil while the player has no
    /// video track yet — a stream's tracks arrive after it opens.
    private func videoIsQuarterRotated() -> Bool? {
        let tracks = player.videoTracks
        guard let track = tracks.first(where: { $0.isSelected }) ?? tracks.first,
              let video = track.video else { return nil }
        return video.orientation.rawValue >= 4
    }

    // MARK: audio boost

    // MARK: sleep timer

    /// Counts down and pauses. Deliberately pause and not stop: waking to a
    /// closed player and a lost position is the failure this feature exists to
    /// avoid, and a paused player still holds its place.
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
                    if self.player.isPlaying { self.togglePlay() }
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

    /// "42m" · "58s" — a badge, so it stays short.
    var sleepLabel: String? {
        guard let left = sleepRemaining else { return nil }
        return left >= 60 ? "\(left / 60)m" : "\(left)s"
    }

    func setAudioBoost(_ percent: Int) {
        audioBoost = max(100, min(200, percent))
        let audio: VLCAudio? = player.audio
        audio?.volume = Int32(audioBoost)
    }
    private func reapplyAudioBoost() {
        guard audioBoost != 100 else { return }
        let audio: VLCAudio? = player.audio
        audio?.volume = Int32(audioBoost)
    }

    // MARK: preferred languages

    /// Auto-select the audio/subtitle track in the user's preferred language.
    /// Runs once per item when its tracks first appear, and when the preference
    /// changes mid-playback.
    ///
    /// The setting stores an English language name ("Telugu"). libVLC 4 gives
    /// each track its language code, so a track matches when that code names the
    /// language — which catches the many streams whose track titles say only
    /// "Track 2" — or, failing that, when its title contains the name.
    func applyPreferredLanguages() {
        let defaults = UserDefaults.standard
        if let pa = defaults.string(forKey: "preferred_audio_language"), !pa.isEmpty,
           let id = Self.trackIndex(in: player.audioTracks, matching: pa) {
            selectAudio(id)
        }
        if let ps = defaults.string(forKey: "preferred_subtitle_language"), !ps.isEmpty,
           let id = Self.trackIndex(in: player.textTracks, matching: ps) {
            selectSubtitle(id)
        }
    }

    private static func trackIndex(in tracks: [VLCMediaPlayer.Track], matching language: String) -> Int? {
        let english = Locale(identifier: "en")
        if let byCode = tracks.firstIndex(where: { track in
            guard let code = track.language, !code.isEmpty,
                  let name = english.localizedString(forLanguageCode: code) else { return false }
            return name.caseInsensitiveCompare(language) == .orderedSame
        }) {
            return byCode
        }
        return tracks.firstIndex { displayName(of: $0).range(of: language, options: .caseInsensitive) != nil }
    }

    /// The title libVLC gives a track, else its language, else a placeholder.
    private static func displayName(of track: VLCMediaPlayer.Track) -> String {
        if !track.trackName.isEmpty { return track.trackName }
        if let code = track.language, !code.isEmpty,
           let name = Locale(identifier: "en").localizedString(forLanguageCode: code) {
            return name
        }
        return track.trackDescription ?? "Track"
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
        guard let item, !item.isLocal else { return }
        // Skip only what cannot be a master playlist. The old test demanded a
        // `hls` content type or an `.m3u8` path, which hid the picker on exactly
        // the streams this app sees most: extensionless CDN playlists with no
        // manifest rule to type them. `HLSVariants.fetch` reads at most 64 KB and
        // parses nothing without `#EXT-X-STREAM-INF`, so probing costs little and
        // a wrong guess costs nothing.
        let type = item.contentType?.lowercased()
        guard type != "mp4", type != "dash" else { return }
        let path = item.url.path.lowercased()
        guard !path.hasSuffix(".mp4"), !path.hasSuffix(".mkv"),
              !path.hasSuffix(".webm"), !path.hasSuffix(".mpd")
        else { return }

        let url = item.url, headers = item.headers
        let itemId = item.id
        Task { [weak self] in
            guard let seconds = await HLSVariants.duration(url: url, headers: headers) else { return }
            await MainActor.run {
                guard let self, self.item?.id == itemId else { return }
                self.playlistDurationMs = Int(seconds * 1000)
                self.videoDrawable?.lengthMs = Int64(self.durationMs)
                self.invalidatePictureInPicture()
            }
        }
        Task { [weak self] in
            let variants = await HLSVariants.fetch(url: url, headers: headers)
            guard variants.count > 1 else { return }
            await MainActor.run {
                guard let self else { return }
                self.qualities = [Quality.auto] + variants.map {
                    Quality(
                        id: "\($0.height)_\($0.bandwidth)",
                        label: $0.height > 0 ? "\($0.height)p" : "\($0.bandwidth / 1000) kbps",
                        url: $0.url,
                        bandwidth: $0.bandwidth
                    )
                }
            }
        }
    }

    // MARK: helpers exposed to the view

    var totalSeconds: Double { Double(durationMs) / 1000 }

    /// Length from libVLC's length event, else the media's own, else elapsed
    /// plus remaining — whichever is known first for this stream.
    ///
    /// libVLC 4 derives length from media timestamps, and MPEG-TS timestamps are
    /// 33-bit at 90 kHz: they roll over every 2^33 / 90000 s, about 26 h 30 m.
    /// A stream whose clock starts near that rollover reads a day too long — a
    /// three-hour film shown as 29 hours. A finished HLS playlist states its
    /// real length, so that wins; anything else past a full rollover has the
    /// rollover taken off, since nothing this app plays is a day long.
    private var durationMs: Int {
        if playlistDurationMs > 0 { return playlistDurationMs }
        if lengthMs > 0 { return Self.unwrapped(Int(lengthMs)) }
        if let media = player.media, media.length.intValue > 0 {
            return Self.unwrapped(Int(media.length.intValue))
        }
        let remaining: VLCTime? = player.remainingTime
        return Self.unwrapped(Int(player.time.intValue) + abs(Int(remaining?.intValue ?? 0)))
    }

    /// 2^33 / 90 kHz, in milliseconds.
    private static let tsClockWrapMs = 95_443_718

    private static func unwrapped(_ ms: Int) -> Int {
        var value = ms
        while value > tsClockWrapMs { value -= tsClockWrapMs }
        return value
    }
    var elapsedSeconds: Double { Double(player.time.intValue) / 1000 }

    static func clock(_ seconds: Double) -> String { fmt(Int32(max(0, seconds) * 1000)) }

    // MARK: lock screen / Control Center

    /// Populate the Now Playing card. VLC (unlike AVPlayer) never does this for
    /// us, which is why no media notification appeared.
    private func updateNowPlaying() {
        let elapsedMs = Int(player.time.intValue)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: (item?.title.isEmpty == false ? item!.title : "Panura"),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(elapsedMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
        ]
        let durationMs = self.durationMs
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
                let total = self.durationMs
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
                // Picture in Picture is the reason to keep playing; it owns the
                // picture while it runs.
                guard let self, !self.backgroundPlayEnabled, !self.isPictureInPictureActive else { return }
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
        // Returning from PiP: the output was never torn down, and rebuilding it
        // would drop the PiP controller with it.
        guard !isPictureInPictureActive, let drawable = videoDrawable else { return }
        player.drawable = nil
        player.drawable = drawable
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

    /// Defined once, in `ResumePosition`, so removing a Home card and forgetting
    /// a position cannot drift apart.
    private static func resumeKey(_ url: URL) -> String {
        ResumePosition.key(url.absoluteString)
    }

    private func applyResumeIfPending() {
        let total = totalSeconds
        guard !resumeApplied, let target = pendingResumeSeconds, total > 0 else { return }
        // Only seek once the tail leaves room — never resume into the last 15s.
        guard target < total - 15 else { resumeApplied = true; return }
        player.time = VLCTime(int: Int32(clamping: Int(target * 1000)))
        resumeApplied = true
    }

    private func saveResume() {
        // A dead source has already had its row deleted; saving on the way out
        // would re-add exactly the entry that was just dropped.
        guard !resumeEntryRemoved else { return }
        guard resumeEnabled, let item else { return }
        let e = elapsedSeconds, total = totalSeconds
        if total > 0, e > 15, e < total - 15 {
            UserDefaults.standard.set(e, forKey: Self.resumeKey(item.url))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.resumeKey(item.url))
        }
        // Same rule drives the Home row: finished (or barely started) drops off.
        BrowsingStore.shared.updateWatching(url: item.url, position: e, duration: total)
        captureThumbnailIfNeeded()
    }

    /// A resume entry whose source is gone has to go, or Continue Watching keeps
    /// offering something that can only ever fail — the entry stores a CDN URL,
    /// and those expire.
    ///
    /// Only when the source is PROVEN gone. libVLC reports one undifferentiated
    /// error state, with no status code and no distinction between "404" and
    /// "the Wi-Fi dropped", so the evidence has to be fetched: a local file is
    /// checked for existence, and a stream is re-probed, where only 404/410
    /// counts as dead (see `StreamProbe`). Deleting on a timeout instead would
    /// wipe resume points every time the network dips.
    private func dropResumeIfSourceIsGone() {
        guard let item, !resumeEntryRemoved else { return }

        if item.isLocal {
            // A file that is simply missing. The URL keeps resolving long after
            // the bytes are gone, which is why the check is on the file itself.
            guard !FileManager.default.fileExists(atPath: item.url.path) else { return }
            forgetResume(item)
            return
        }

        Task { [weak self] in
            let outcome = await StreamProbe.probe(
                url: item.url, headers: item.headers, ruleMatched: false
            )
            guard !outcome.active else { return }
            await MainActor.run { self?.forgetResume(item) }
        }
    }

    private func forgetResume(_ item: MediaItem) {
        UserDefaults.standard.removeObject(forKey: Self.resumeKey(item.url))
        BrowsingStore.shared.removeWatching(url: item.url.absoluteString)
        resumeEntryRemoved = true
    }

    /// One frame per played item, for the Continue Watching card.
    private var sleepTask: Task<Void, Never>?

    private var thumbnailCaptured = false

    /// Asks libVLC for the frame rather than snapshotting `drawableView`: VLC
    /// renders into its own surface, so a UIView capture comes back empty.
    ///
    /// Deliberately late — a frame grabbed during the first seconds is usually
    /// a title card or black, and by 15s the item has also earned its place on
    /// Home, so the two thresholds are the same one.
    private func captureThumbnailIfNeeded() {
        guard !thumbnailCaptured, let item, player.isPlaying else { return }
        // No guard against audio-only media: libVLC simply writes no file, and
        // the existence check below is already the arbiter.
        guard elapsedSeconds > 15 else { return }
        thumbnailCaptured = true

        let path = ResumeThumbnails.path(for: item.url)
        player.saveVideoSnapshot(at: path, withWidth: 280, andHeight: 0)

        // The write is asynchronous with no completion, so confirm the file
        // landed before pointing an entry at it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard FileManager.default.fileExists(atPath: path) else { return }
            BrowsingStore.shared.setThumbnail(url: item.url, path: path)
        }
    }

    // MARK: track loading

    /// Set once an item's tracks have been matched against the preferred
    /// languages, so a later track event does not undo the user's own pick.
    private var preferredLanguagesApplied = false

    private func loadTracksIfNeeded() {
        guard !tracksLoaded else { return }
        refreshTracks()
    }

    /// Mirrors libVLC's track lists into the sheets. libVLC 4 announces every
    /// track that appears, disappears or changes selection — a sidecar subtitle
    /// arrives well after the stream's own tracks — so this runs on each of
    /// those, not just once.
    fileprivate func refreshTracks() {
        let audio = player.audioTracks
        let text = player.textTracks
        audioTracks = audio.enumerated().map { Track(id: $0.offset, name: Self.displayName(of: $0.element)) }
        subtitleTracks = text.enumerated().map { Track(id: $0.offset, name: Self.displayName(of: $0.element)) }
        currentAudioId = audio.firstIndex(where: { $0.isSelected }) ?? -1
        currentSubtitleId = text.firstIndex(where: { $0.isSelected }) ?? -1

        guard !audio.isEmpty || !text.isEmpty else { return }
        tracksLoaded = true
        if !preferredLanguagesApplied {
            preferredLanguagesApplied = true
            applyPreferredLanguages()
        }
    }

    // MARK: Picture in Picture

    private func pictureInPictureReady(_ controller: VLCPictureInPictureWindowControlling) {
        pipController = controller
        pipAvailable = AVPictureInPictureController.isPictureInPictureSupported()
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    /// The PiP window shows its own play state and progress, and reads them
    /// again only when told something changed.
    /// PiP has gone. Work out whether to put the player back up.
    ///
    /// The Apple player is told outright: AVKit calls
    /// `restoreUserInterfaceForPictureInPictureStop` when the restore button is
    /// the reason, and says nothing when the close button is. VLCKit's whole
    /// PiP surface is `stateChangeEventHandler(BOOL isStarted)` — one bool,
    /// the same for both buttons — so the reason has to be inferred, and the
    /// difference that is left is playback itself: restore returns you to the
    /// video still playing, close stops it.
    ///
    /// Hence the beat before deciding. The stop arrives before the pause that
    /// comes with it, so reading `isPlaying` in this turn of the run loop
    /// always says "playing" and would reopen the player on a close too.
    ///
    /// Known limit: pause the video inside the PiP window and then restore it,
    /// and this reads as a close and leaves the player shut. The Now Playing
    /// bar is still there, and tapping it is the way back.
    private func pictureInPictureStopped() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !self.isPictureInPictureActive, self.isPlaying else { return }
            PlaybackSession.shared.restore()
        }
    }

    fileprivate func invalidatePictureInPicture() {
        pipController?.invalidatePlaybackState()
    }

    private static func fmt(_ ms: Int32) -> String {
        let total = max(0, Int(ms) / 1000)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

extension VLCPlayerModel: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in
            isPlaying = player.isPlaying
            invalidatePictureInPicture()
            switch newState {
            case .opening:
                buffering = true
                scheduleBufferWatchdog()
            case .playing:
                bufferWatchdog?.cancel()
                buffering = false; failure = nil
                loadTracksIfNeeded()
                reapplySync()
                reapplyAudioBoost()
                applyAspect()
                detectVideoOrientation()
            case .error:
                // One more attempt before calling it dead, through the relay.
                // It is a genuinely different request, not the same one twice:
                // the relay re-serves the playlist as
                // application/vnd.apple.mpegurl, hands every segment back under
                // an extensionless URL with its real Content-Type, and strips
                // decoy image headers on the way through. libVLC picks its
                // demuxer from MIME and extension, so a CDN that names its TS
                // segments `.svg` — or serves a playlist as text/plain — fails
                // direct and plays relayed.
                if retryThroughRelay() { return }
                buffering = false
                failure = "This stream could not be opened."
                dropResumeIfSourceIsGone()
            default: break
            }
            updateNowPlaying()
        }
    }

    /// libVLC 4 has no buffering state; it reports progress instead, from 0 to 1.
    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor in
            let stalled = progress < 1 && !player.isPlaying
            buffering = stalled
            if stalled { scheduleBufferWatchdog() } else { bufferWatchdog?.cancel() }
        }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor in
            lengthMs = length
            videoDrawable?.lengthMs = Int64(durationMs)
            invalidatePictureInPicture()
        }
    }

    // Track events: a track appeared, went away, or changed selection.
    nonisolated func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor in refreshTracks() }
    }

    nonisolated func mediaPlayerTrackRemoved(_ trackId: String, with trackType: VLCMedia.TrackType) {
        Task { @MainActor in refreshTracks() }
    }

    nonisolated func mediaPlayerTrackSelected(_ trackType: VLCMedia.TrackType, selectedId: String, unselectedId: String) {
        Task { @MainActor in refreshTracks() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            let elapsedMs = Int(player.time.intValue)
            let totalMs = durationMs
            position = totalMs > 0 ? Float(min(1, Double(elapsedMs) / Double(totalMs))) : Float(player.position)
            elapsed = Self.fmt(Int32(clamping: elapsedMs))
            remaining = "-" + Self.fmt(Int32(clamping: max(0, totalMs - elapsedMs)))
            total = Self.fmt(Int32(clamping: totalMs))
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

// MARK: - PlayerEngine

extension VLCPlayerModel: PlayerEngine {
    /// Through the session — see AVPlayerModel.makeEngine.
    static func makeEngine() -> VLCPlayerModel { PlaybackSession.shared.vlcEngine() }

    var supportsAudioDelay: Bool { true }
    var supportsAudioBoost: Bool { true }
    var supportsSubtitleDelay: Bool { true }
    /// VLCKit 4 floats its own sample-buffer layer; available once the video
    /// output has handed over its controller.
    var supportsPictureInPicture: Bool { pipAvailable }
    var supportsAirPlay: Bool { false }
    /// libVLC renders every subtitle into the picture itself.
    var overlaySubtitle: String? { nil }

    func makeVideoView() -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    /// libVLC's text renderer reads its style when media opens.
    func subtitleStyleChanged() { reopenPreservingPosition() }
}
