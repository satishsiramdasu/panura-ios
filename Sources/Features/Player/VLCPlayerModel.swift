import Foundation
import UIKit
import AVFoundation
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
    @Published var rate: Float = 1.0

    @Published var audioTracks: [Track] = []
    @Published var subtitleTracks: [Track] = []

    struct Track: Identifiable, Hashable { let id: Int; let name: String }

    let player = VLCMediaPlayer()
    private var tracksLoaded = false

    func start(item: MediaItem, into view: UIView) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        player.drawable = view
        player.delegate = self

        let media = VLCMedia(url: item.url)
        applyHeaders(item.headers, to: media)
        player.media = media
        player.play()
    }

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
    func stop() { player.stop() }

    func selectAudio(_ id: Int) { player.currentAudioTrackIndex = Int32(id) }
    func selectSubtitle(_ id: Int) { player.currentVideoSubTitleIndex = Int32(id) }

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
            case .playing: buffering = false; loadTracksIfNeeded()
            default: break
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            position = player.position
            elapsed = Self.fmt(player.time.intValue)
            remaining = Self.fmt(player.remainingTime.intValue)
            buffering = false
            loadTracksIfNeeded()
        }
    }
}
