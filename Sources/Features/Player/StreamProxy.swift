import Foundation
import Swifter

/// Local HTTP relay, used for two distinct reasons.
///
/// 1. Headers VLC cannot send. It manages referer/user-agent/cookie itself, but
///    a CDN checking `Origin` (or anything else we captured) would refuse it.
///    We hand VLC a `127.0.0.1` URL and fetch upstream with every header
///    verbatim — the same idea as the Android CastServer:8888 relay.
/// 2. Content type. Some CDNs serve an extensionless HLS playlist as
///    `text/plain`; libVLC picks its demuxer from MIME and extension, so it
///    never reaches the adaptive demuxer. Re-serving the playlist as
///    `application/vnd.apple.mpegurl` (with a `.m3u8` hint on the proxy URL)
///    is what makes such a stream playable at all.
///
/// Playlists are rewritten either way, including `URI="…"` attributes
/// (EXT-X-KEY, EXT-X-MEDIA renditions): their URIs are relative to a document
/// that now lives on 127.0.0.1, so they must at minimum be absolutised. They
/// are pointed back at the relay only when reason 1 applies — otherwise VLC
/// fetches segments directly rather than through a local socket.
final class StreamProxy {
    static let shared = StreamProxy()

    private let server = HttpServer()
    private var started = false
    private var port: UInt16 = 0
    /// session → header set captured at detection time, and whether HEVC
    /// `hev1` tags are renamed on the way through.
    private var sessions: [String: Session] = [:]
    private struct Session {
        var headers: [String: String]
        var renameHEVCTags: Bool
    }
    /// id → upstream URL. The URL is kept HERE rather than encoded into the
    /// proxy URL: base64 of a real segment URL routinely contains `/` and `=`,
    /// and query-string parsing mangles both (`+` also decodes to a space), so
    /// every segment request failed while the shorter playlist URL happened to
    /// survive. An opaque id in the path has nothing to misparse.
    private var targets: [String: (url: URL, session: String)] = [:]
    /// "session|url" → id, so a URL repeated in a playlist reuses its id.
    private var targetIDs: [String: String] = [:]
    private var currentSession: String?
    private var counter = 0
    private let lock = NSLock()

    private init() { route() }

    // MARK: public

    /// Returns a localhost URL that proxies `url` using `headers`.
    /// Falls back to the original URL if the server can't start.
    ///
    /// `playlistHint` appends `.m3u8` to the proxy URL. libVLC decides its
    /// demuxer from the extension as well as the MIME type, and these CDNs give
    /// it neither — so the hint plus the relay's corrected Content-Type make
    /// both agree that this is HLS.
    ///
    /// `renameHEVCTags` turns `hev1` into `hvc1` in playlist CODECS attributes
    /// and init segments, for the Apple player — see `HEVCTagPatcher`.
    func proxied(
        url: URL, headers: [String: String], playlistHint: Bool = false, renameHEVCTags: Bool = false
    ) -> URL {
        guard start() else { return url }
        let session = UUID().uuidString
        lock.lock()
        // Starting a new item retires the previous one's registry — a long VOD
        // playlist can register thousands of segments.
        if let old = currentSession {
            sessions[old] = nil
            targets = targets.filter { $0.value.session != old }
            targetIDs = targetIDs.filter { !$0.key.hasPrefix("\(old)|") }
        }
        currentSession = session
        sessions[session] = Session(headers: headers, renameHEVCTags: renameHEVCTags)
        lock.unlock()
        return proxyURL(for: url, session: session, suffix: playlistHint ? ".m3u8" : "") ?? url
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

    /// Register `target` and return its localhost URL. Both path components are
    /// a UUID and a base-36 counter, so nothing needs escaping.
    private func proxyURL(for target: URL, session: String, suffix: String = "") -> URL? {
        let key = "\(session)|\(target.absoluteString)"
        lock.lock()
        let id: String
        if let existing = targetIDs[key] {
            id = existing
        } else {
            counter += 1
            id = String(counter, radix: 36)
            targets[id] = (target, session)
            targetIDs[key] = id
        }
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/p/\(session)/\(id)\(suffix)")
    }

    private func route() {
        server["/p/:session/:id"] = { [weak self] request in
            guard let self,
                  let session = request.params[":session"],
                  let id = request.params[":id"]
            else { return .badRequest(nil) }

            // The id may carry the .m3u8 demuxer hint; it is not part of the key.
            let key = id.hasSuffix(".m3u8") ? String(id.dropLast(5)) : id
            self.lock.lock()
            let headers = self.sessions[session]?.headers ?? [:]
            let renameTags = self.sessions[session]?.renameHEVCTags ?? false
            let target = self.targets[key]?.url
            self.lock.unlock()

            guard let target else { return .badRequest(nil) }

            // Pass the client's Range through so seeking works on progressive files.
            let range = request.headers["range"]
            guard let result = self.fetch(target, headers: headers, range: range) else {
                return .internalServerError
            }

            if self.isPlaylist(target: target, mime: result.mime, body: result.body) {
                var rewritten = self.rewritePlaylist(result.body, base: target, session: session)
                if renameTags, let text = String(data: rewritten, encoding: .utf8) {
                    rewritten = Data(HEVCTagPatcher.renameCodecs(text).utf8)
                }
                return .ok(.data(rewritten, contentType: "application/vnd.apple.mpegurl"))
            }

            // Only safe on a whole-body response: stripping bytes would
            // invalidate the offsets a ranged request was answered with.
            var body = range == nil ? Self.stripDecoyHeader(result.body) : result.body
            // Init segments are a few kilobytes. A media segment is only walked
            // at its top level — moof, mdat — and comes back untouched.
            if renameTags, range == nil, body.count <= 8_000_000, let renamed = HEVCTagPatcher.patch(body) {
                body = renamed
            }

            var out = ["Content-Type": result.mime ?? "application/octet-stream"]
            result.contentRange.map { out["Content-Range"] = $0 }
            out["Accept-Ranges"] = "bytes"
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

    // MARK: decoy headers

    /// Some CDNs glue a small valid image (commonly a 69-byte PNG) to the front
    /// of every MPEG-TS segment to disguise it. FFmpeg-based players survive
    /// this because their TS demuxer hunts for the 0x47 sync byte; libVLC probes
    /// the first bytes, sees an image, and refuses the stream — so it never
    /// plays at all. Strip the decoy so what we serve starts at a packet.
    ///
    /// Content-driven, not per-site: it only fires when the body opens with an
    /// image magic AND a real 188-byte TS lock is found behind it, so genuine
    /// media (and genuine images) pass through untouched.
    static func stripDecoyHeader(_ body: Data) -> Data {
        let imageMagics: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47],   // PNG
            [0xFF, 0xD8, 0xFF],         // JPEG
            [0x47, 0x49, 0x46, 0x38],   // GIF
            [0x52, 0x49, 0x46, 0x46],   // RIFF/WEBP
        ]
        let bytes = [UInt8](body.prefix(8192))
        guard bytes.count > 8,
              imageMagics.contains(where: { bytes.starts(with: $0) })
        else { return body }

        let total = body.count
        for offset in 0..<bytes.count where bytes[offset] == 0x47 {
            let available = min(20, (total - offset) / 188)
            guard available >= 2 else { break }
            var locked = 0
            var i = offset
            while locked < available, i < total, body[body.startIndex + i] == 0x47 {
                locked += 1
                i += 188
            }
            if locked == available {
                return body.subdata(in: (body.startIndex + offset)..<body.endIndex)
            }
        }
        return body
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
    private func rewritePlaylist(_ data: Data, base: URL, session: String) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }

        let lines = text.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }

            if trimmed.hasPrefix("#") {
                // Rewrite URI="…" (EXT-X-KEY, EXT-X-MEDIA audio/subtitle renditions).
                return rewriteURIAttribute(in: line, base: base, session: session)
            }
            // A bare line is a segment or variant playlist.
            guard let abs = URL(string: trimmed, relativeTo: base)?.absoluteURL,
                  let proxied = proxyURL(for: abs, session: session) else { return line }
            return proxied.absoluteString
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func rewriteURIAttribute(in line: String, base: URL, session: String) -> String {
        guard let start = line.range(of: "URI=\"") else { return line }
        let after = line[start.upperBound...]
        guard let end = after.range(of: "\"") else { return line }
        let uri = String(after[..<end.lowerBound])
        guard let abs = URL(string: uri, relativeTo: base)?.absoluteURL,
              let proxied = proxyURL(for: abs, session: session) else { return line }
        return line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(proxied.absoluteString)\"")
    }
}
