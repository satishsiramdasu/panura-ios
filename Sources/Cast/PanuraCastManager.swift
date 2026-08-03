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

    /// Skip the direct probe and always serve through this phone. Direct mode is
    /// judged from what the CDN tells *us*, which cannot account for everything
    /// the TV's player will refuse — this is the escape hatch when a stream is
    /// detected fine, casts as direct, and then never starts on the TV.
    ///
    /// Persisted by hand rather than with `@AppStorage`: that lives in SwiftUI,
    /// and a model has no business importing it.
    /// Spelled with the concrete type, not `Self`: a stored property initializer
    /// on a class cannot reference the covariant `Self`.
    @Published var forceProxy =
        UserDefaults.standard.bool(forKey: PanuraCastManager.forceProxyKey) {
        didSet {
            UserDefaults.standard.set(forceProxy, forKey: PanuraCastManager.forceProxyKey)
        }
    }

    fileprivate static let forceProxyKey = "cast_force_proxy"

    private let server = PanuraCastServer()

    /// Numbers each log line. The list is keyed by its text, and two identical
    /// entries — the same segment fetched twice, the same probe verdict on a
    /// re-cast — would otherwise collide.
    private var logSequence = 0

    /// Newest-first, capped. Every route the cast could have taken writes here.
    private func log(_ line: String) {
        logSequence += 1
        proxyLog.insert("\(logSequence).  \(line)", at: 0)
        if proxyLog.count > 12 { proxyLog.removeLast() }
    }

    /// URL of the cast in flight. The direct-cast watchdog compares against this
    /// so a stall never downgrades a stream the user has since replaced.
    private var castID = ""

    private init() {
        server.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        server.onClientCountChanged = { [weak self] count in
            Task { @MainActor in self?.clientCountChanged(count) }
        }
        server.onProxyRequest = { [weak self] what, status, bytes in
            Task { @MainActor in
                let size = bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
                self?.log("\(status)  \(size)  \(what)")
            }
        }
        // Sockets and the Bonjour registration do not survive suspension. On
        // return the listener is dead, and `start()` would early-return on
        // isServerRunning and never republish — the phone believes it is
        // discoverable while the TV can no longer see it.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.republishIfStale() }
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
        if isServerRunning {
            // Healthy: nothing to do. Stale (sockets up, advertisement gone —
            // typically after suspension): tear down and rebuild, or the retry
            // button and the foreground check would both be no-ops.
            guard !isAdvertising else { return }
            server.stop()
            isServerRunning = false
        }
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

    /// Rebuilds the server when it is nominally up but no longer advertising.
    /// Cheap when healthy: a live advertisement short-circuits it.
    private func republishIfStale() {
        guard isServerRunning, !isAdvertising else { return }
        start()   // start() itself rebuilds a stale server
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
        castID = ""
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
        // Untrimmed: the TV needs everything the page sent, and the proxy must
        // fetch on the same terms the TV would.
        server.headers = item.castHeaders
        guard let proxy = PanuraCastServer.proxyURL(for: item.url) else {
            lastError = "No Wi-Fi address — the TV has no way to reach this device."
            return
        }

        isCasting = true
        streamTitle = item.title
        castID = item.url.absoluteString

        let skipProbe = forceProxy
        Task { [weak self] in
            let probe = skipProbe
                ? Probe(headers: nil, reason: "forced by the always-proxy setting")
                : await Self.probeDirect(item.url, headers: item.castHeaders)
            let direct = probe.headers
            guard let self else { return }
            // Why this cast went the way it did. Without it "via phone" is a
            // verdict with no evidence, and the three routes to it — the decoy
            // check, a refused probe, the toggle — are indistinguishable.
            self.log((direct == nil ? "via phone: " : "direct: ") + probe.reason)
            if let direct {
                // The TV sends exactly these and nothing else. When a direct cast
                // that probed clean still stalls, this line against Android's
                // "Cast mode: Direct → … (headers=…)" is what names the difference.
                self.log("TV sends: " + direct.keys.sorted().joined(separator: ", "))
            }

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
            message.subtitleHeaders = item.castHeaders

            self.server.send(message)
            self.mode = direct == nil ? "proxy" : "direct"
            if direct != nil { self.watchDirectCast(item, proxyURL: proxyURL) }
        }
    }

    /// Re-sends through the proxy if a direct cast never starts.
    ///
    /// Predicting what the TV will refuse does not work: the phone can only ask
    /// the CDN what *it* will serve, and a CDN can answer a probe perfectly while
    /// the TV's player rejects what arrives — a decoy-prefixed segment being the
    /// case in hand. The TV reports its own position, so stop guessing and watch
    /// it: no progress within the grace period means direct failed, whatever the
    /// reason, and the proxy path is known to work.
    private func watchDirectCast(_ item: MediaItem, proxyURL: String) {
        let expected = item.url.absoluteString
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self,
                  self.isCasting,
                  self.mode == "direct",
                  self.castID == expected,
                  self.playback.positionMs == 0,
                  !self.playback.isPlaying
            else { return }

            var message = CastMessage(type: "stream")
            message.streamUrl = proxyURL
            message.proxyUrl = proxyURL
            message.title = item.title
            message.mode = "proxy"
            message.subtitles = item.subtitles.map {
                CastSubtitle(url: $0.url.absoluteString, label: $0.label, lang: $0.language)
            }
            message.subtitleHeaders = item.castHeaders
            self.server.send(message)
            self.mode = "proxy"
            self.log("direct stalled after 12s — retrying through this phone")
        }
    }

    /// The probe's verdict and, in plain words, what decided it.
    private struct Probe {
        /// Headers the TV should send, or nil when only the proxy will do.
        let headers: [String: String]?
        let reason: String
    }

    /// Returns the header set the CDN accepts for a TV-side fetch, or nil when it
    /// won't serve one at all. Tries the captured headers, then a set with
    /// Referer/Origin/Sec-Fetch removed — some CDNs reject a Referer they didn't
    /// issue, and those stream fine bare.
    private static func probeDirect(_ url: URL, headers: [String: String]) async -> Probe {
        switch await inspectSegments(url, headers: headers) {
        // A CDN that prefixes its segments with a decoy image must be proxied
        // however willing it is to serve the TV. The receiver plays through
        // ExoPlayer, whose TS extractor probes the first bytes and refuses on
        // seeing PNG/JPEG/GIF magic — the stream simply never starts, which is
        // what "plays on the phone, loads forever on the TV" means. libVLC hunts
        // for the sync byte and survives it, and our proxy strips it outright.
        case .decoy:
            return Probe(headers: nil, reason: "segments carry a decoy image header")
        // The playlist being served says nothing about the segments: gating them
        // separately is common, and the TV then fetches a perfectly good playlist
        // and stalls on the first segment. Probing only the manifest is what let
        // that reach the TV and cost 12s before the watchdog noticed.
        case .refused(let status):
            return Probe(
                headers: nil,
                reason: "playlist served, segments refused (\(describe(status)))")
        case .playable, .unknown:
            break
        }

        let full = await head(url, headers: headers)
        if let full, (200...299).contains(full) {
            return Probe(headers: headers, reason: "CDN answered \(full) with the page's headers")
        }
        let stripped = headers.filter { key, _ in
            let k = key.lowercased()
            return k != "referer" && k != "origin" && !k.hasPrefix("sec-fetch")
        }
        guard stripped.count != headers.count else {
            return Probe(headers: nil, reason: "CDN refused the probe (\(describe(full)))")
        }
        let bare = await head(url, headers: stripped)
        if let bare, (200...299).contains(bare) {
            return Probe(headers: stripped, reason: "CDN answered \(bare) without Referer/Origin")
        }
        return Probe(
            headers: nil,
            reason: "CDN refused both probes (\(describe(full)) with headers, "
                + "\(describe(bare)) bare)")
    }

    private static func describe(_ status: Int?) -> String {
        guard let status else { return "no response" }
        return "HTTP \(status)"
    }

    private enum SegmentVerdict {
        /// Fetched, and the opening bytes are a container ExoPlayer accepts.
        case playable
        /// Fetched, but prefixed with an image ExoPlayer's TS extractor rejects.
        case decoy
        /// The CDN would not serve the segment to a client sending these headers.
        case refused(Int?)
        /// Not HLS, or the playlist could not be walked — direct stays available.
        case unknown
    }

    /// Follows the playlist down to a real segment and reports what a TV-side
    /// fetch would actually get.
    ///
    /// Both halves matter and they fail differently. A refusal means the CDN gates
    /// segments even though it served the manifest; a decoy means it served the
    /// bytes and ExoPlayer will not take them. Everything unrecognised stays
    /// `unknown` and leaves direct available — guessing the other way would tether
    /// the phone for every stream we cannot classify.
    private static func inspectSegments(_ url: URL, headers: [String: String]) async -> SegmentVerdict {
        guard let playlist = await text(url, headers: headers, bytes: 65_535),
              playlist.contains("#EXTM3U")
        else { return .unknown }

        // One level down a master playlist to reach real segments.
        var mediaPlaylist = playlist
        var base = url
        if playlist.contains("#EXT-X-STREAM-INF"),
           let variant = firstURI(in: playlist, base: url) {
            guard let nested = await text(variant, headers: headers, bytes: 65_535) else {
                return .refused(nil)
            }
            mediaPlaylist = nested
            base = variant
        }

        guard let segment = firstURI(in: mediaPlaylist, base: base) else { return .unknown }
        let (status, body) = await fetch(segment, headers: headers, count: 8)
        guard let status, (200...299).contains(status) else { return .refused(status) }
        guard let head = body, head.count >= 4 else { return .unknown }

        // Images first, and GIF is the reason why: its magic is 47 49 46 38, and
        // that leading 0x47 is also the MPEG-TS sync byte. Testing for TS first
        // would wave every GIF-prefixed segment through as clean.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let gif: [UInt8] = [0x47, 0x49, 0x46, 0x38]
        if Array(head.prefix(4)) == png { return .decoy }
        if Array(head.prefix(3)) == jpeg { return .decoy }
        if Array(head.prefix(4)) == gif { return .decoy }

        if head[0] == 0x47 { return .playable }                                // clean MPEG-TS
        if head.count >= 8, Array(head[4..<8]) == Array("ftyp".utf8) { return .playable }
        if head.count >= 8, Array(head[4..<8]) == Array("styp".utf8) { return .playable }
        return .unknown
    }

    /// First non-comment URI in a playlist, resolved against `base`.
    private static func firstURI(in playlist: String, base: URL) -> URL? {
        for line in playlist.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return URL(string: trimmed, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    private static func text(_ url: URL, headers: [String: String], bytes limit: Int) async -> String? {
        let (status, data) = await fetch(url, headers: headers, count: limit)
        guard let status, (200...299).contains(status), let data else { return nil }
        return String(data: Data(data), encoding: .utf8)
    }

    /// Ranged GET returning the status alongside the opening bytes. The status is
    /// the point: a refusal and an unreadable body are different verdicts, and
    /// collapsing both to nil is what let a segment-gated stream pass the probe.
    private static func fetch(
        _ url: URL, headers: [String: String], count: Int
    ) async -> (Int?, [UInt8]?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-\(count - 1)", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return (nil, nil)
        }
        return ((response as? HTTPURLResponse)?.statusCode, [UInt8](data))
    }

    /// The status the CDN gives this URL for a plain client with these headers,
    /// or nil when the request never completed.
    ///
    /// `HEAD` first, then a one-byte ranged `GET` if the server rejects the
    /// method. Plenty of CDNs answer 405/501 to HEAD while serving GET perfectly
    /// — treating those as a failure would proxy streams that the TV could fetch
    /// itself, tethering the phone for no reason.
    private static func head(_ url: URL, headers: [String: String]) async -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 405 || http.statusCode == 501 else { return http.statusCode }

        var ranged = URLRequest(url: url)
        ranged.timeoutInterval = 8
        for (key, value) in headers { ranged.setValue(value, forHTTPHeaderField: key) }
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, rangedResponse) = try? await URLSession.shared.data(for: ranged),
              let rangedHTTP = rangedResponse as? HTTPURLResponse else { return nil }
        return rangedHTTP.statusCode
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
