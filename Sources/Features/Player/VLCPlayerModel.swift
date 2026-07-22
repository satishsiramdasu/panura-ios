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
    @Published var remaining = "-0:00"
    @Published var buffering = true
    /// Non-nil when playback failed, so the UI says so instead of spinning.
    @Published var failure: String?
    @Published var rate: Float = 1.0

    @Published var audioTracks: [Track] = []
    @Published var subtitleTracks: [Track] = []

    struct Track: Identifiable, Hashable { let id: Int; let name: String }

    let player = VLCMediaPlayer()
    private var tracksLoaded = false
    private var title = ""
    private var observersAdded = false

    /// User setting — when off, playback pauses as soon as the app leaves the
    /// foreground (screen lock, home). When on, audio keeps going.
    private var backgroundPlayEnabled: Bool {
        UserDefaults.standard.bool(forKey: "background_play")
    }

    func start(item: MediaItem, into view: UIView) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        title = item.title
        player.drawable = view
        player.delegate = self

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
                playlistHint: needsTypeRelay,
                relayChildren: needsHeaderRelay
              )
            : item.url

        let media = VLCMedia(url: playURL)
        // Harmless belt-and-braces for the direct (unproxied) path.
        applyHeaders(item.headers, to: media)
        player.media = media
        player.play()

        // Sidecar subtitles sniffed from the page — the stream itself usually
        // carries none, so without these there are no captions at all.
        for track in item.subtitles {
            player.addPlaybackSlave(track.url, type: .subtitle, enforce: false)
        }

        setupRemoteCommands()
        observeLifecycle()
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

    // MARK: transport

    func togglePlay() { player.isPlaying ? player.pause() : player.play() }
    func skip(_ seconds: Int) {
        seconds >= 0 ? player.jumpForward(Int32(seconds)) : player.jumpBackward(Int32(-seconds))
    }
    func seek(to fraction: Float) { player.position = fraction }
    func setRate(_ r: Float) { player.rate = r; rate = r }
    func stop() {
        player.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func selectAudio(_ id: Int) { player.currentAudioTrackIndex = Int32(id) }
    func selectSubtitle(_ id: Int) { player.currentVideoSubTitleIndex = Int32(id) }

    // MARK: lock screen / Control Center

    /// Populate the Now Playing card. VLC (unlike AVPlayer) never does this for
    /// us, which is why no media notification appeared.
    private func updateNowPlaying() {
        let elapsedMs = Int(player.time.intValue)
        // remainingTime is negative; derive duration without touching media.length.
        let remainingMs = abs(Int(player.remainingTime?.intValue ?? 0))
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Panura" : title,
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

    // MARK: helpers

    private func loadTracksIfNeeded() {
        guard !tracksLoaded else { return }
        let aIdx = (player.audioTrackIndexes as? [NSNumber]) ?? []
        let aName = (player.audioTrackNames as? [String]) ?? []
        audioTracks = zip(aIdx, aName).map { Track(id: $0.intValue, name: $1) }

        let sIdx = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        let sName = (player.videoSubTitlesNames as? [String]) ?? []
        subtitleTracks = zip(sIdx, sName).map { Track(id: $0.intValue, name: $1) }

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
            case .playing: buffering = false; failure = nil; loadTracksIfNeeded()
            case .error:
                // Previously swallowed by `default`, which left a failed stream
                // spinning forever with nothing said.
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
            elapsed = Self.fmt(player.time.intValue)
            remaining = Self.fmt(player.remainingTime?.intValue ?? 0)
            buffering = false
            loadTracksIfNeeded()
            updateNowPlaying()
        }
    }
}
