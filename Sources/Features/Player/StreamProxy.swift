import Foundation
import Swifter

/// Local HTTP relay so gated streams play with their FULL captured header set.
///
/// VLC can only send referer/user-agent/cookie; a CDN that also checks `Origin`
/// (or anything else we captured) would refuse it. Instead we hand VLC a
/// `127.0.0.1` URL and this server fetches upstream with every header verbatim.
/// Same idea as the Android CastServer:8888 relay.
///
/// HLS matters here: a playlist's segment/variant URIs must ALSO come back
/// through the proxy, otherwise VLC would fetch those directly and bare — so
/// playlists are rewritten, including `URI="…"` attributes (EXT-X-KEY and
/// EXT-X-MEDIA audio renditions).
final class StreamProxy {
    static let shared = StreamProxy()

    private let server = HttpServer()
    private var started = false
    private var port: UInt16 = 0
    /// token → header set captured at detection time.
    private var sessions: [String: [String: String]] = [:]
    private let lock = NSLock()

    private init() { route() }

    // MARK: public

    /// Returns a localhost URL that proxies `url` using `headers`.
    /// Falls back to the original URL if the server can't start.
    func proxied(url: URL, headers: [String: String]) -> URL {
        guard start() else { return url }
        let token = UUID().uuidString
        lock.lock(); sessions[token] = headers; lock.unlock()
        return proxyURL(for: url, token: token) ?? url
    }

    // MARK: server

    @discardableResult
    private func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return true }
        do {
            try server.start(0, forceIPv4: true)   // 0 = OS picks a free port
            port = UInt16(try server.port())
            started = true
            return true
        } catch {
            return false
        }
    }

    private func proxyURL(for target: URL, token: String) -> URL? {
        let encoded = Data(target.absoluteString.utf8).base64EncodedString()
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(port)
        comps.path = "/p/\(token)"
        comps.queryItems = [URLQueryItem(name: "u", value: encoded)]
        return comps.url
    }

    private func route() {
        server["/p/:token"] = { [weak self] request in
            guard let self,
                  let token = request.params[":token"],
                  let encoded = request.queryParams.first(where: { $0.0 == "u" })?.1,
                  let data = Data(base64Encoded: encoded),
                  let urlString = String(data: data, encoding: .utf8),
                  let target = URL(string: urlString)
            else { return .badRequest(nil) }

            self.lock.lock()
            let headers = self.sessions[token] ?? [:]
            self.lock.unlock()

            // Pass the client's Range through so seeking works on progressive files.
            let range = request.headers["range"]
            guard let result = self.fetch(target, headers: headers, range: range) else {
                return .internalServerError
            }

            if self.isPlaylist(target: target, mime: result.mime, body: result.body) {
                let rewritten = self.rewritePlaylist(result.body, base: target, token: token)
                return .ok(.data(rewritten, contentType: "application/vnd.apple.mpegurl"))
            }

            var out = ["Content-Type": result.mime ?? "application/octet-stream"]
            result.contentRange.map { out["Content-Range"] = $0 }
            out["Accept-Ranges"] = "bytes"
            let body = result.body
            return .raw(result.status, result.status == 206 ? "Partial Content" : "OK", out) { writer in
                try writer.write(body)
            }
        }
    }

    // MARK: upstream fetch

    private struct Result {
        let body: Data
        let mime: String?
        let status: Int
        let contentRange: String?
    }

    /// Synchronous by design — Swifter serves each request on its own thread.
    private func fetch(_ url: URL, headers: [String: String], range: String?) -> Result? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // Replay every captured header verbatim (Referer, Origin, UA, Cookie…).
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }

        var result: Result?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let data else { return }
            let http = response as? HTTPURLResponse
            result = Result(
                body: data,
                mime: http?.value(forHTTPHeaderField: "Content-Type") ?? response?.mimeType,
                status: http?.statusCode ?? 200,
                contentRange: http?.value(forHTTPHeaderField: "Content-Range")
            )
        }.resume()
        _ = done.wait(timeout: .now() + 35)
        return result
    }

    // MARK: HLS rewriting

    private func isPlaylist(target: URL, mime: String?, body: Data) -> Bool {
        if let mime, mime.lowercased().contains("mpegurl") { return true }
        let path = target.path.lowercased()
        if path.hasSuffix(".m3u8") { return true }
        // Some CDNs serve playlists as .txt — sniff the magic line.
        return body.prefix(7) == Data("#EXTM3U".utf8)
    }

    /// Point every URI in the playlist back at this proxy, resolved absolutely.
    private func rewritePlaylist(_ data: Data, base: URL, token: String) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }

        let lines = text.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }

            if trimmed.hasPrefix("#") {
                // Rewrite URI="…" (EXT-X-KEY, EXT-X-MEDIA audio/subtitle renditions).
                return rewriteURIAttribute(in: line, base: base, token: token)
            }
            // A bare line is a segment or variant playlist.
            guard let abs = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                  let proxied = proxyURL(for: abs, token: token) else { return line }
            return proxied.absoluteString
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func rewriteURIAttribute(in line: String, base: URL, token: String) -> String {
        guard let start = line.range(of: "URI=\"") else { return line }
        let after = line[start.upperBound...]
        guard let end = after.range(of: "\"") else { return line }
        let uri = String(after[..<end.lowerBound])
        guard let abs = URL(string: uri, relativeTo: base)?.absoluteURL,
              let proxied = proxyURL(for: abs, token: token) else { return line }
        return line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(proxied.absoluteString)\"")
    }
}
