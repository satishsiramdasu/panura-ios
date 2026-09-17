import Foundation

/// One HLS master-playlist variant (a selectable quality level).
struct HLSVariant: Hashable {
    let height: Int      // 0 when the variant carries no RESOLUTION attribute
    let bandwidth: Int   // bits/sec
    let url: URL
}

/// Parses the `#EXT-X-STREAM-INF` variants out of an HLS master playlist so the
/// player can offer a manual quality picker — VLC only does adaptive selection
/// internally and exposes no variant list.
enum HLSVariants {
    /// Safe to call for any URL that might be HLS. A ranged request caps the read
    /// at 64 KB — comfortably more than any master playlist, and small enough
    /// that aiming this at a progressive MP4 costs one truncated chunk instead of
    /// the whole file. A server that ignores `Range` is handled the same way,
    /// since the body is only ever scanned for playlist markers.
    static func fetch(url: URL, headers: [String: String]) async -> [HLSVariant] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let text = String(data: data, encoding: .utf8),
              text.contains("#EXT-X-STREAM-INF") else { return [] }
        return parse(text, base: url)
    }

    /// Total duration of a finished (VOD) HLS stream in seconds: the sum of its
    /// `#EXTINF` segment durations. For a master playlist the first variant is
    /// read instead — every rendition of one title runs the same length. nil for
    /// a live playlist (no `#EXT-X-ENDLIST`) or anything that is not HLS.
    ///
    /// The player's own length comes from media timestamps, and those can be
    /// wrong in ways the playlist cannot: see `VLCPlayerModel.durationMs`.
    static func duration(url: URL, headers: [String: String]) async -> Double? {
        guard let text = await playlistText(url: url, headers: headers) else { return nil }
        if text.contains("#EXT-X-STREAM-INF") {
            guard let first = parse(text, base: url).last,
                  let media = await playlistText(url: first.url, headers: headers) else { return nil }
            return mediaDuration(media)
        }
        return mediaDuration(text)
    }

    /// A long VOD playlist runs to hundreds of kilobytes, so this read is not
    /// capped the way `fetch` is — but it is still refused past a few megabytes,
    /// which no playlist reaches and any video file does.
    private static func playlistText(url: URL, headers: [String: String]) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-4194303", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U") || text.contains("#EXTINF") || text.contains("#EXT-X-STREAM-INF")
        else { return nil }
        return text
    }

    private static func mediaDuration(_ text: String) -> Double? {
        guard text.contains("#EXT-X-ENDLIST") else { return nil }
        var total = 0.0
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXTINF:") {
            let value = line.dropFirst("#EXTINF:".count).prefix { $0 != "," }
            total += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return total > 0 ? total : nil
    }

    static func parse(_ text: String, base: URL) -> [HLSVariant] {
        var out: [HLSVariant] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let height = value("RESOLUTION", in: line)
                    .flatMap { $0.split(separator: "x").last }
                    .flatMap { Int($0) } ?? 0
                let bandwidth = value("BANDWIDTH", in: line).flatMap { Int($0) } ?? 0
                // The next non-empty, non-comment line is the variant URI.
                var j = i + 1
                while j < lines.count {
                    let uri = lines[j].trimmingCharacters(in: .whitespaces)
                    if uri.isEmpty || uri.hasPrefix("#") { j += 1; continue }
                    if let vurl = URL(string: uri, relativeTo: base)?.absoluteURL {
                        out.append(HLSVariant(height: height, bandwidth: bandwidth, url: vurl))
                    }
                    break
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        // Highest quality first; collapse duplicate heights (keep richest bitrate).
        var seenHeights = Set<Int>()
        return out
            .sorted { ($0.height, $0.bandwidth) > ($1.height, $1.bandwidth) }
            .filter { $0.height == 0 || seenHeights.insert($0.height).inserted }
    }

    /// Extract `KEY=VALUE` (value may be quoted) from an EXT-X-STREAM-INF line.
    private static func value(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: "\(key)=") else { return nil }
        var rest = line[r.upperBound...]
        if rest.first == "\"" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        return String(rest[..<end])
    }
}
