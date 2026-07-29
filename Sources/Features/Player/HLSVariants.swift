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
    /// Only call for URLs already known to be HLS: this reads the whole body, so
    /// pointing it at a progressive MP4 would download the file.
    static func fetch(url: URL, headers: [String: String]) async -> [HLSVariant] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let text = String(data: data, encoding: .utf8),
              text.contains("#EXT-X-STREAM-INF") else { return [] }
        return parse(text, base: url)
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
