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

    /// Bonjour has actually published us. Driven by the listener's own state —
    /// never assumed, because a failed publish is invisible otherwise.
    @Published private(set) var isAdvertising = false
    /// Sockets are bound. Casting needs this; being discoverable is separate.
    @Published private(set) var isServerRunning = false
    @Published private(set) var isTVConnected = false
    @Published private(set) var connectedTVName = ""
    @Published private(set) var isCasting = false
    @Published private(set) var streamTitle = ""
    /// "direct" (TV fetches the CDN itself, phone may leave the network) or
    /// "proxy" (every byte goes through this device).
    @Published private(set) var mode = ""
    @Published private(set) var playback = PanuraPlayback()
    /// Set when the server could not bind or Bonjour refused to publish — nearly
    /// always the local-network permission.
    @Published private(set) var lastError: String?
    /// Newest first: status, size and what was fetched, for each request the TV
    /// made. Empty while casting means the TV never asked this device for
    /// anything — a different fault from asking and being refused.
    @Published private(set) var proxyLog: [String] = []

    private let server = PanuraCastServer()

    private init() {
        server.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        server.onClientCountChanged = { [weak self] count in
            Task { @MainActor in self?.clientCountChanged(count) }
        }
        server.onProxyRequest = { [weak self] what, status, bytes in
            Task { @MainActor in
                guard let self else { return }
                let size = bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
                self.proxyLog.insert("\(status)  \(size)  \(what)", at: 0)
                if self.proxyLog.count > 12 { self.proxyLog.removeLast() }
            }
        }
        server.onAdvertisingChanged = { [weak self] advertising, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAdvertising = advertising
                if let error {
                    self.lastError = error
                } else if advertising {
                    self.lastError = nil
                }
            }
        }
    }

    // MARK: connection

    /// Starts advertising. Idempotent — casting calls this first, so the user
    /// never has to "connect" before picking a video.
    func start() {
        guard !isServerRunning else { return }
        if server.start() {
            isServerRunning = true
            // isAdvertising is NOT set here — it follows the listener going ready.
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
        isServerRunning = false
        isTVConnected = false
        connectedTVName = ""
        isCasting = false
        mode = ""
        streamTitle = ""
        playback = PanuraPlayback()
    }

    /// Stops what is playing but stays discoverable, so the next cast needs no
    /// rediscovery on the TV.
    func stopStream() {
        server.send(CastMessage(type: "stop"))
        isCasting = false
        streamTitle = ""
        mode = ""
        playback = PanuraPlayback()
    }

    // MARK: casting

    /// Sends `item` to the TV, choosing direct or proxy the way Android does.
    ///
    /// Direct means the TV fetches the CDN itself and the phone can leave the
    /// network; proxy means every byte goes through this device. Direct is
    /// preferable whenever the CDN will accept the TV's request, so we probe
    /// first — and the probe must fail exactly where the TV would, or picking
    /// direct simply moves the rejection onto the TV.
    func cast(_ item: MediaItem) {
        start()
        guard isServerRunning else { return }

        server.streamURL = item.url
        server.headers = item.headers
        guard let proxy = PanuraCastServer.proxyURL(for: item.url) else {
            lastError = "No Wi-Fi address — the TV has no way to reach this device."
            return
        }

        isCasting = true
        streamTitle = item.title

        Task { [weak self] in
            let direct = await Self.probeDirect(item.url, headers: item.headers)
            guard let self else { return }

            // Nonce: the TV keys its player on the URL, so replacing a stream
            // needs a distinct one or it will not reload.
            let proxyURL = proxy + "?v=\(Int(Date().timeIntervalSince1970 * 1000))"

            var message = CastMessage(type: "stream")
            message.streamUrl = direct == nil ? proxyURL : item.url.absoluteString
            message.proxyUrl = proxyURL
            message.title = item.title
            message.mode = direct == nil ? "proxy" : "direct"
            message.headers = direct ?? [:]
            message.subtitles = item.subtitles.map {
                CastSubtitle(url: $0.url.absoluteString, label: $0.label, lang: $0.language)
            }
            // Always the full captured set, never the trimmed one — the subtitle
            // host is usually a different origin from the video CDN and often
            // wants the opposite headers.
            message.subtitleHeaders = item.headers

            self.server.send(message)
            self.mode = direct == nil ? "proxy" : "direct"
        }
    }

    /// Returns the header set the CDN accepts for a TV-side fetch, or nil when it
    /// won't serve one at all. Tries the captured headers, then a set with
    /// Referer/Origin/Sec-Fetch removed — some CDNs reject a Referer they didn't
    /// issue, and those stream fine bare.
    private static func probeDirect(_ url: URL, headers: [String: String]) async -> [String: String]? {
        if await head(url, headers: headers) { return headers }
        let stripped = headers.filter { key, _ in
            let k = key.lowercased()
            return k != "referer" && k != "origin" && !k.hasPrefix("sec-fetch")
        }
        guard stripped.count != headers.count else { return nil }
        return await head(url, headers: stripped) ? stripped : nil
    }

    /// True when the CDN will serve this URL to a plain client with these headers.
    ///
    /// `HEAD` first, then a one-byte ranged `GET` if the server rejects the
    /// method. Plenty of CDNs answer 405/501 to HEAD while serving GET perfectly
    /// — treating those as a failure would proxy streams that the TV could fetch
    /// itself, tethering the phone for no reason.
    private static func head(_ url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        if (200...299).contains(http.statusCode) { return true }
        guard http.statusCode == 405 || http.statusCode == 501 else { return false }

        var ranged = URLRequest(url: url)
        ranged.timeoutInterval = 8
        for (key, value) in headers { ranged.setValue(value, forHTTPHeaderField: key) }
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, rangedResponse) = try? await URLSession.shared.data(for: ranged),
              let rangedHTTP = rangedResponse as? HTTPURLResponse else { return false }
        return (200...299).contains(rangedHTTP.statusCode)
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
        guard count > 0 else {
            connectedTVName = ""
            playback = PanuraPlayback()
            return
        }
        // Introduce ourselves on every connect, not just at start: a TV that
        // joins later has no other way to learn which phone it is paired with.
        var hello = CastMessage(type: "hello")
        hello.deviceName = UIDevice.current.name
        server.send(hello)
    }
}
