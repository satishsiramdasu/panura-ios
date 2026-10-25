import Foundation

/// Liveness + quality probe for a detected stream — the iOS half of Android's
/// `BrowserViewModel.executeProbe`.
///
/// Two things come out of it, and the found-bar needs both: whether the URL is
/// reachable at all, and what it is (adaptive master vs single rendition, its
/// resolution, its size). Nothing else in the app can answer either — the URL
/// shape says nothing about liveness, and an extensionless manifest says nothing
/// about resolution.
///
/// **Fail-safe on purpose.** A probe rejection is not proof a link is dead:
/// 403/429/405 normally mean "this probe is not allowed" while the player, which
/// replays the full captured header set, plays it fine. Only a definitively-gone
/// status (404/410) marks a stream inactive, and only that drops it from the
/// list.
enum StreamProbe {
    /// Statuses that prove the source is gone rather than merely refusing us.
    static let goneStatuses: Set<Int> = [404, 410]

    enum State: Hashable {
        /// Direct-media URL, probe in flight.
        case pending
        /// Reachable.
        case active
        /// 404/410 — gone.
        case inactive
        /// Not a direct-media URL (an embed page): nothing to probe.
        case skipped
    }

    struct Result: Hashable {
        /// "1920×1080", when a playlist or a rendition named one.
        var resolution: String?
        /// "412 MB" for a single file; "1.2–3.4 GB" for an HLS master, from
        /// the lowest and highest declared bitrate times the running time.
        var fileSize: String?
        /// "1h 52m", "Live", or nil when unknown.
        var duration: String?
        /// `Adaptive` for a master playlist, `Single` for a media-only one,
        /// nil for anything that is not HLS.
        var hlsType: String?

        /// Pixel count from `resolution`, 0 when there is none. One definition,
        /// because the list orders by it and the found-bar's top pick comes from
        /// that order — the row at the top is always the one Play would use.
        var pixels: Int {
            guard let resolution else { return 0 }
            let parts = resolution.split(whereSeparator: { $0 == "×" || $0 == "x" })
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return 0 }
            return w * h
        }

        /// The height half — "1920×1080" → "1080p" — because that is the number
        /// people pick streams by, and it fits where the full pair does not. An
        /// adaptive master has no single resolution to name, so it reads "Auto".
        var qualityTag: String? {
            if hlsType == "Adaptive" { return "Auto" }
            guard let resolution else { return nil }
            let parts = resolution.split(whereSeparator: { $0 == "×" || $0 == "x" })
            guard parts.count == 2, let h = Int(parts[1]) else { return nil }
            return "\(h)p"
        }
    }

    struct Outcome {
        var active: Bool
        var result: Result?
    }

    /// True for URLs that are the media itself rather than a page holding it.
    /// Mirrors Android's `isDirectMediaUrl`.
    static func isDirectMedia(_ url: URL) -> Bool {
        let full = url.absoluteString.lowercased()
        let path = full.components(separatedBy: "?").first ?? full
        if [".m3u8", ".mpd", ".mp4", ".webm", ".mkv"].contains(where: path.hasSuffix) { return true }
        if path.contains("/hls/"), !path.hasSuffix(".js"), !path.hasSuffix(".mjs") { return true }
        if path.hasSuffix(".txt"),
           ["master", "index", "playlist"].contains(where: path.contains) { return true }
        return full.contains(".m3u8") || full.contains(".mpd")
    }

    private static func looksHLS(_ url: URL) -> Bool {
        let full = url.absoluteString.lowercased()
        let path = full.components(separatedBy: "?").first ?? full
        return path.hasSuffix(".m3u8") || path.contains("/hls/") || full.contains(".m3u8")
    }

    /// Is this link still worth offering? The question Continue Watching asks,
    /// which is narrower than `probe` — no quality, no size, just whether the
    /// resource is definitively gone.
    ///
    /// Fail-safe in the same way and for the same reason: a CDN that 403s a
    /// bare probe usually plays fine for the player, which replays the whole
    /// captured header set, and a network error proves nothing at all. Only
    /// 404/410 count as gone. Android's `LocalStreamResumeRepository.probe`
    /// makes exactly this call and the two must agree, or the same saved stream
    /// survives on one phone and vanishes on the other.
    static func isAlive(url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        // A range keeps the probe to a couple of KB of a file that may be
        // gigabytes; a CDN that ignores it answers 200 and we read nothing more.
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        for (name, value) in headers where !value.isEmpty {
            let key = name.lowercased()
            guard key != "host", key != "content-length", key != "range" else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if headers.keys.first(where: { $0.lowercased() == "user-agent" }) == nil {
            request.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
        }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return true }
        return !goneStatuses.contains(http.statusCode)
    }

    /// Strict version of `isAlive`, for an address somebody has just typed.
    ///
    /// The difference is what an unanswered request means. `isAlive` reads it
    /// as "alive" on purpose: it sweeps resume cards, and a flaky minute of
    /// signal must not throw away somebody's place in a film. Here the
    /// opposite is true — nothing has been opened yet, and a player that
    /// appears and immediately dies says less than a line of text under the
    /// field. So an address that cannot be reached, or that answers with an
    /// error, fails the check.
    ///
    /// A redirect to a login page still passes. Only the server can say
    /// whether the bytes are there, and plenty of CDNs answer a probe
    /// differently from a player.
    static func reachable(url: URL, headers: [String: String]) async -> Bool {
        // Nothing to probe: libVLC speaks these and URLSession does not.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return true
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        for (name, value) in headers where !value.isEmpty {
            let key = name.lowercased()
            guard key != "host", key != "content-length", key != "range" else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if headers.keys.first(where: { $0.lowercased() == "user-agent" }) == nil {
            request.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
        }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode < 400
    }

    /// Probes `url`, replaying the headers the browser captured for it.
    ///
    /// `ruleMatched` streams are NOT read: a single-use-token host spends its
    /// token on whoever fetches the playlist first, and if that is the probe the
    /// player's own fetch comes back 410. Those are reported active, unread.
    static func probe(
        url: URL,
        headers: [String: String],
        ruleMatched: Bool
    ) async -> Outcome {
        let path = url.absoluteString.lowercased().components(separatedBy: "?").first ?? ""
        let isHLS = looksHLS(url)
        // Explicit playlist files stay active on a refusal: auth-gated CDNs
        // answer 4xx to a probe carrying no session, and the player — which
        // sends the browser's cookies — plays them.
        let looksLikeHlsFile = path.hasSuffix(".m3u8") || path.hasSuffix(".txt")

        if ruleMatched {
            return Outcome(active: true, result: isHLS ? Result(hlsType: "Adaptive") : nil)
        }

        if isHLS {
            guard let (status, body) = await get(url, headers: headers, byteLimit: 65_536) else {
                return Outcome(active: true)   // a network error proves nothing
            }
            guard (200..<300).contains(status) else { return Outcome(active: looksLikeHlsFile) }
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // A body that is not a playlist means the URL only *looked* like one
            // — a /hls/ path match on an HTML error page, say.
            guard text.hasPrefix("#EXTM3U") else { return Outcome(active: looksLikeHlsFile) }
            let isMaster = text.range(of: "#EXT-X-STREAM-INF", options: .caseInsensitive) != nil
            // Running time and size, as Android's found sheet shows them. A
            // master names no length, so its highest rung's media playlist is
            // read once for the sum of EXTINF; size is each end of the bitrate
            // ladder times that.
            var duration: String?
            var size: String?
            if isMaster {
                let rungs = variants(in: text, base: url)
                if let top = rungs.max(by: { $0.bps < $1.bps }),
                   let (status, media) = await get(top.url, headers: headers, byteLimit: 2_000_000),
                   (200..<300).contains(status), media.hasPrefix("#EXTM3U") {
                    let seconds = playlistSeconds(media)
                    duration = formatDuration(media, seconds: seconds)
                    let rates = rungs.map(\.bps).filter { $0 > 0 }
                    if let seconds, seconds > 0, let lo = rates.min(), let hi = rates.max() {
                        size = sizeRange(lo * seconds / 8, hi * seconds / 8)
                    }
                }
            } else {
                duration = formatDuration(text, seconds: playlistSeconds(text))
            }
            return Outcome(
                active: true,
                result: Result(
                    resolution: bestResolution(in: text),
                    fileSize: size,
                    duration: duration,
                    hlsType: isMaster ? "Adaptive" : "Single"
                )
            )
        }

        // Try with the browser's Referer/Cookie first — referer-gated CDNs need
        // them. Then bare: an OSS referer *whitelist* does the opposite and
        // rejects any Referer it does not know while allowing none at all.
        var head = await headRequest(url, headers: headers)
        if !(200..<300).contains(head.status) {
            let retry = await headRequest(url, headers: [:])
            if (200..<300).contains(retry.status) { head = retry }
        }
        if (200..<300).contains(head.status) {
            return Outcome(
                active: true,
                result: Result(fileSize: head.length > 0 ? formatSize(head.length) : nil)
            )
        }
        return Outcome(active: !goneStatuses.contains(head.status))
    }

    /// Largest `RESOLUTION=` in a playlist. A media playlist rarely carries one
    /// at all, which is why the found-bar falls back to the `hlsType` label.
    static func bestResolution(in manifest: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "RESOLUTION=(\\d+)x(\\d+)", options: [.caseInsensitive]
        ) else { return nil }
        let ns = manifest as NSString
        var best: String?
        var bestPixels = 0
        for match in regex.matches(in: manifest, range: NSRange(location: 0, length: ns.length)) {
            guard let w = Int(ns.substring(with: match.range(at: 1))),
                  let h = Int(ns.substring(with: match.range(at: 2))) else { continue }
            if w * h > bestPixels { bestPixels = w * h; best = "\(w)×\(h)" }
        }
        return best
    }

    /// Bits per second and absolute playlist URL for each rung of a master.
    ///
    /// AVERAGE-BANDWIDTH when the rung declares it, BANDWIDTH otherwise.
    /// BANDWIDTH is the peak, and sized off it a film read a third larger
    /// than it is — which is why the Save dialog and this agree on average.
    static func variants(in master: String, base: URL) -> [(bps: Double, url: URL)] {
        var out: [(Double, URL)] = []
        var pending: Double?
        for raw in master.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("#EXT-X-STREAM-INF") {
                pending = attribute("AVERAGE-BANDWIDTH", in: line)
                    ?? attribute("BANDWIDTH", in: line) ?? 0
            } else if let bps = pending, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL { out.append((bps, url)) }
                pending = nil
            }
        }
        return out
    }

    /// A numeric attribute, matched as a whole name — `BANDWIDTH` must not
    /// match inside `AVERAGE-BANDWIDTH`.
    private static func attribute(_ name: String, in line: String) -> Double? {
        let pattern = "(?<![-A-Z])" + name + "=(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return Double(line[range])
    }

    /// Sum of EXTINF, or nil for a live playlist (no ENDLIST) or none.
    static func playlistSeconds(_ media: String) -> Double? {
        guard media.contains("#EXT-X-ENDLIST") else { return nil }
        var total = 0.0
        for line in media.components(separatedBy: .newlines) where line.hasPrefix("#EXTINF:") {
            let value = line.dropFirst(8).split(separator: ",").first.map(String.init) ?? ""
            total += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return total > 0 ? total : nil
    }

    static func formatDuration(_ media: String, seconds: Double?) -> String? {
        if !media.contains("#EXT-X-ENDLIST"), media.contains("#EXTINF") { return "Live" }
        guard let seconds else { return nil }
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s % 60)s" }
        return "\(s)s"
    }

    /// "1.2–3.4 GB", or "~3.4 GB" when the ladder has one rung.
    static func sizeRange(_ low: Double, _ high: Double) -> String {
        let lo = formatSize(Int64(low)), hi = formatSize(Int64(high))
        if lo == hi { return "~" + hi }
        let loParts = lo.split(separator: " "), hiParts = hi.split(separator: " ")
        if loParts.count == 2, hiParts.count == 2, loParts[1] == hiParts[1] {
            return "\(loParts[0])–\(hi)"
        }
        return "\(lo)–\(hi)"
    }

    static func formatSize(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.0f MB", b / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.0f KB", b / 1_024) }
        return "\(bytes) B"
    }

    // MARK: requests

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.httpShouldSetCookies = false      // we replay the page's own cookie
        return URLSession(configuration: config)
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if headers["User-Agent"] == nil {
            request.setValue(fallbackUA, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")
    }

    /// Only used when the detection carried no UA of its own.
    private static let fallbackUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static func headRequest(
        _ url: URL, headers: [String: String]
    ) async -> (status: Int, length: Int64) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        apply(headers, to: &request)
        guard let (_, response) = try? await session().data(for: request),
              let http = response as? HTTPURLResponse else { return (-1, -1) }
        return (http.statusCode, http.expectedContentLength)
    }

    /// A bounded GET. Bounded because a server answering an HLS URL with an HTML
    /// error page — or with media — can hand back hundreds of megabytes, and the
    /// only part that identifies a playlist is its first line.
    private static func get(
        _ url: URL, headers: [String: String], byteLimit: Int
    ) async -> (Int, String)? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(byteLimit - 1)", forHTTPHeaderField: "Range")
        apply(headers, to: &request)
        guard let (data, response) = try? await session().data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let slice = data.prefix(byteLimit)
        return (http.statusCode, String(decoding: slice, as: UTF8.self))
    }
}
