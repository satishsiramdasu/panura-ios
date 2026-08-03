import Foundation
import UIKit

/// Drives PanuraCast: brings the server up, tracks whether a TV is on the other
/// end, sends streams, and relays transport commands.
///
/// "Connected" here has two distinct meanings, and conflating them is the usual
/// source of a UI that lies. `isAdvertising` means our server is up and we are
/// discoverable; `isTVConnected` means a TV has actually opened its socket.
/// Only the second one means a cast will go anywhere.
@MainActor
final class PanuraCastManager: ObservableObject {
    static let shared = PanuraCastManager()

    @Published private(set) var isAdvertising = false
    @Published private(set) var isTVConnected = false
    @Published private(set) var connectedTVName = ""
    @Published private(set) var isCasting = false
    @Published private(set) var streamTitle = ""
    @Published private(set) var playback = PanuraPlayback()
    /// Set when the server could not bind or Bonjour refused to publish — nearly
    /// always the local-network permission.
    @Published private(set) var lastError: String?

    private let server = PanuraCastServer()

    private init() {
        server.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        server.onClientCountChanged = { [weak self] count in
            Task { @MainActor in self?.clientCountChanged(count) }
        }
    }

    // MARK: connection

    /// Starts advertising. Idempotent — casting calls this first, so the user
    /// never has to "connect" before picking a video.
    func start() {
        guard !isAdvertising else { return }
        if server.start() {
            isAdvertising = true
            lastError = nil
            // Announce ourselves to whoever is already listening.
            var hello = CastMessage(type: "hello")
            hello.deviceName = UIDevice.current.name
            server.send(hello)
        } else {
            lastError = "Could not start the cast server. Check that Panura has "
                + "local network access in Settings."
        }
    }

    func stop() {
        server.send(CastMessage(type: "stop"))
        server.stop()
        isAdvertising = false
        isTVConnected = false
        connectedTVName = ""
        isCasting = false
        streamTitle = ""
        playback = PanuraPlayback()
    }

    /// Stops what is playing but stays discoverable, so the next cast needs no
    /// rediscovery on the TV.
    func stopStream() {
        server.send(CastMessage(type: "stop"))
        isCasting = false
        streamTitle = ""
        playback = PanuraPlayback()
    }

    // MARK: casting

    /// Sends `item` to the TV. Always proxy mode for now: the phone fetches with
    /// the captured headers and re-serves, which works for every gated CDN. The
    /// direct-mode probe Android does (letting the TV fetch the CDN itself, so
    /// the phone can leave the network) is not ported yet.
    func cast(_ item: MediaItem) {
        start()
        guard isAdvertising else { return }

        server.streamURL = item.url
        server.headers = item.headers
        guard let proxy = PanuraCastServer.proxyURL(for: item.url) else {
            lastError = "No Wi-Fi address — the TV has no way to reach this device."
            return
        }
        // Nonce: the TV keys its player on the URL, so replacing a stream needs a
        // distinct one or it will not reload.
        let url = proxy + "?v=\(Int(Date().timeIntervalSince1970 * 1000))"

        var message = CastMessage(type: "stream")
        message.streamUrl = url
        message.proxyUrl = url
        message.title = item.title
        message.mode = "proxy"
        message.subtitles = item.subtitles.map {
            CastSubtitle(url: $0.url.absoluteString, label: $0.label, lang: $0.language)
        }
        // Always the full captured set — the subtitle host is usually a different
        // origin from the video CDN, with its own requirements.
        message.subtitleHeaders = item.headers
        server.send(message)

        isCasting = true
        streamTitle = item.title
    }

    // MARK: transport

    func playPause() { control("playpause") }
    func play() { control("play") }
    func pause() { control("pause") }
    func seek(toMs ms: Int64) { control("seekTo", long: ms) }
    func seek(byMs ms: Int64) { control("seekBy", long: ms) }
    func setVolume(_ v: Float) { control("volume", float: v) }
    func selectAudioTrack(_ id: Int) { control("audioTrack", long: Int64(id)) }
    func selectSubtitleTrack(_ id: Int) { control("subtitleTrack", long: Int64(id)) }
    func disableSubtitles() { control("subtitleOff") }

    private func control(_ command: String, long: Int64 = 0, float: Float = 0) {
        guard isTVConnected else { return }
        var message = CastMessage(type: "control")
        message.command = command
        message.valueLong = long
        message.valueFloat = float
        server.send(message)
    }

    // MARK: inbound

    private func handle(_ message: CastMessage) {
        switch message.type {
        case "ping":
            server.send(CastMessage(type: "pong"))
        case "hello":
            connectedTVName = message.deviceName
        case "status":
            playback = PanuraPlayback(
                positionMs: message.positionMs,
                durationMs: message.durationMs,
                isPlaying: message.isPlaying,
                isLive: message.isLive,
                volume: message.volume,
                audioTracks: message.audioTracks,
                subtitleTracks: message.subtitleTracks
            )
        default:
            break
        }
    }

    private func clientCountChanged(_ count: Int) {
        isTVConnected = count > 0
        if count == 0 {
            connectedTVName = ""
            playback = PanuraPlayback()
        }
    }
}
