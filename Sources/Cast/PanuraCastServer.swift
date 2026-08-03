import Foundation
import Swifter
import UIKit

/// The phone half of PanuraCast: a Bonjour advertisement, a WebSocket server the
/// TV connects back to, and an HTTP proxy that fetches the stream with headers
/// the TV cannot send itself.
///
/// Roles are the reverse of what "casting" suggests — the **phone is the server**
/// and the TV is the client. The TV finds us over `_panura._tcp.` on :8888, then
/// opens a WebSocket to :8889. Both ports are fixed because the Android receiver
/// hard-codes them.
final class PanuraCastServer: NSObject {
    static let httpPort: UInt16 = 8888
    static let socketPort: UInt16 = 8889
    static let serviceType = "_panura._tcp."

    private let http = HttpServer()
    private let socket = HttpServer()
    private var service: NetService?

    private var clients: [WebSocketSession] = []
    /// Last "stream" message, replayed to any client that connects afterwards.
    /// The TV finishes discovery and connects *after* the phone has already sent
    /// the stream, so a one-shot broadcast would be lost — the same late-join
    /// problem the Android side solves this way.
    private var lastStream: String?

    /// Registered upstream URLs for `/pl/` and `/seg/`, so a rewritten playlist
    /// can point back here without stuffing a URL into a query string.
    private var targets: [String: URL] = [:]
    private var targetIDs: [String: String] = [:]
    private var counter = 0

    private let lock = NSLock()

    /// Stream currently being served, with the headers to fetch it.
    var streamURL: URL?
    var headers: [String: String] = [:]

    var onMessage: ((CastMessage) -> Void)?
    var onClientCountChanged: ((Int) -> Void)?

    // MARK: lifecycle

    private(set) var isRunning = false

    func start() -> Bool {
        guard !isRunning else { return true }
        routeHTTP()
        routeSocket()
        do {
            try http.start(Self.httpPort, forceIPv4: true)
            try socket.start(Self.socketPort, forceIPv4: true)
        } catch {
            http.stop(); socket.stop()
            return false
        }
        advertise()
        isRunning = true
        return true
    }

    func stop() {
        service?.stop()
        service = nil
        http.stop()
        socket.stop()
        lock.lock()
        clients.removeAll()
        lastStream = nil
        targets.removeAll()
        targetIDs.removeAll()
        lock.unlock()
        isRunning = false
    }

    /// Publishes on :8888 — the port the TV resolves. It then connects to :8889
    /// by convention, which is why only one service is advertised.
    private func advertise() {
        let name = UIDevice.current.name
        let service = NetService(
            domain: "local.", type: Self.serviceType, name: name, port: Int32(Self.httpPort)
        )
        service.delegate = self
        service.publish()
        self.service = service
    }

    // MARK: messaging

    func send(_ message: CastMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        if message.type == "stream" { lastStream = json }
        let snapshot = clients
        lock.unlock()
        for client in snapshot { client.writeText(json) }
    }

    private func routeSocket() {
        socket["/"] = websocket(
            text: { [weak self] _, text in
                guard let data = text.data(using: .utf8),
                      let message = try? JSONDecoder().decode(CastMessage.self, from: data)
                else { return }
                self?.onMessage?(message)
            },
            connected: { [weak self] session in
                guard let self else { return }
                self.lock.lock()
                self.clients.append(session)
                let replay = self.lastStream
                let count = self.clients.count
                self.lock.unlock()
                // Late joiner: hand it whatever is currently playing.
                if let replay { session.writeText(replay) }
                self.onClientCountChanged?(count)
            },
            disconnected: { [weak self] session in
                guard let self else { return }
                self.lock.lock()
                self.clients.removeAll { $0 === session }
                let count = self.clients.count
                self.lock.unlock()
                self.onClientCountChanged?(count)
            }
        )
    }

    // MARK: HTTP proxy

    /// Proxy URL for `streamURL`, matching Android's `CastServer.proxyUrl` — the
    /// extension is what tells the TV's player which container to expect, so a
    /// progressive file must not be advertised as a playlist.
    static func proxyURL(for stream: URL?) -> String? {
        guard let ip = localIPv4() else { return nil }
        let path = (stream?.path ?? "").lowercased()
        let progressive = [".mp4", ".mkv", ".webm", ".mov", ".avi"].contains { path.hasSuffix($0) }
        return "http://\(ip):\(httpPort)/stream.\(progressive ? "mp4" : "m3u8")"
    }

    private func routeHTTP() {
        http["/ping"] = { _ in .ok(.text("pong")) }

        // The stream itself. Both paths serve the same thing; only the extension
        // differs, and the TV picks its demuxer from it.
        let serveStream: (HttpRequest) -> HttpResponse = { [weak self] request in
            guard let self, let url = self.streamURL else { return .notFound }
            return self.serve(url, range: request.headers["range"], rewrite: true)
        }
        http["/stream.m3u8"] = serveStream
        http["/stream.mp4"] = serveStream

        // Sub-playlists and segments from a rewritten playlist. Split by role:
        // only `/pl/` is re-parsed, so a segment is never scanned as a playlist.
        http["/pl/:id"] = { [weak self] request in
            guard let self, let id = request.params[":id"], let url = self.target(id)
            else { return .notFound }
            return self.serve(url, range: nil, rewrite: true)
        }
        http["/seg/:id"] = { [weak self] request in
            guard let self, let id = request.params[":id"], let url = self.target(id)
            else { return .notFound }
            return self.serve(url, range: request.headers["range"], rewrite: false)
        }
    }

    private func target(_ id: String) -> URL? {
        let key = id.contains(".") ? String(id.prefix(while: { $0 != "." })) : id
        lock.lock(); defer { lock.unlock() }
        return targets[key]
    }

    /// Fetches upstream with the captured headers and returns it to the TV,
    /// rewriting playlist URIs back through here so segment requests carry the
    /// headers too. Without that the TV fetches segments bare and gets 403.
    private func serve(_ url: URL, range: String?, rewrite: Bool) -> HttpResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }

        var body: Data?
        var mime: String?
        var status = 200
        var contentRange: String?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            body = data
            let http = response as? HTTPURLResponse
            mime = http?.value(forHTTPHeaderField: "Content-Type") ?? response?.mimeType
            status = http?.statusCode ?? 200
            contentRange = http?.value(forHTTPHeaderField: "Content-Range")
        }.resume()
        _ = done.wait(timeout: .now() + 35)

        guard var data = body else { return .internalServerError }

        if rewrite, isPlaylist(url: url, mime: mime, body: data),
           let text = String(data: data, encoding: .utf8) {
            data = Data(rewritePlaylist(text, base: url).utf8)
            return .ok(.data(data, contentType: "application/vnd.apple.mpegurl"))
        }

        // Whole-body only: stripping bytes would invalidate the offsets a ranged
        // response was answered with.
        let out = range == nil ? StreamProxy.stripDecoyHeader(data) : data
        var responseHeaders = ["Content-Type": mime ?? "application/octet-stream",
                               "Accept-Ranges": "bytes"]
        contentRange.map { responseHeaders["Content-Range"] = $0 }
        return .raw(status, status == 206 ? "Partial Content" : "OK", responseHeaders) { writer in
            try writer.write(out)
        }
    }

    private func isPlaylist(url: URL, mime: String?, body: Data) -> Bool {
        if body.starts(with: Array("#EXTM3U".utf8)) { return true }
        if url.path.lowercased().hasSuffix(".m3u8") { return true }
        return (mime ?? "").contains("mpegurl")
    }

    /// Points every URI in a playlist back at this server: sub-playlists to
    /// `/pl/`, everything else (segments, keys, init sections) to `/seg/`.
    private func rewritePlaylist(_ text: String, base: URL) -> String {
        guard let ip = Self.localIPv4() else { return text }
        let root = "http://\(ip):\(Self.httpPort)"

        func proxied(_ raw: String, playlist: Bool) -> String {
            guard let absolute = URL(string: raw, relativeTo: base)?.absoluteURL else { return raw }
            let id = register(absolute)
            // Keep an extension on segments: some players choose a parser by it.
            let suffix = playlist ? ".m3u8" : (absolute.pathExtension.isEmpty ? "" : ".\(absolute.pathExtension)")
            return "\(root)/\(playlist ? "pl" : "seg")/\(id)\(suffix)"
        }

        return text.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if trimmed.hasPrefix("#") {
                // URI="…" carries renditions and keys — absolutise those too, or
                // the TV resolves them against this server and 404s.
                guard let range = trimmed.range(of: "URI=\"") else { return line }
                let rest = trimmed[range.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { return line }
                let uri = String(rest[..<end])
                let isPlaylist = uri.lowercased().contains(".m3u8")
                return trimmed.replacingOccurrences(
                    of: "URI=\"\(uri)\"",
                    with: "URI=\"\(proxied(uri, playlist: isPlaylist))\""
                )
            }
            return proxied(trimmed, playlist: trimmed.lowercased().contains(".m3u8"))
        }.joined(separator: "\n")
    }

    private func register(_ url: URL) -> String {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        if let existing = targetIDs[key] { return existing }
        counter += 1
        let id = String(counter, radix: 36)
        targets[id] = url
        targetIDs[key] = id
        return id
    }

    // MARK: local address

    /// The Wi-Fi address the TV can reach us on. Bonjour resolves this too, but
    /// the proxy URLs we hand the TV have to embed it literally.
    static func localIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }

            let address = String(cString: host)
            let name = String(cString: ptr.pointee.ifa_name)
            // en0 is Wi-Fi on a device; anything else is a fallback (hotspot,
            // wired adapter, simulator).
            if name == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }
}

extension PanuraCastServer: NetServiceDelegate {
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        // Almost always the local-network permission being denied; the TV simply
        // never finds us, so surface it rather than failing silently.
        onClientCountChanged?(0)
    }
}
