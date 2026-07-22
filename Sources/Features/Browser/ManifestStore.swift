import Foundation

/// Reads the remote extractor manifest (same file the Android app uses) so
/// detection rules can be fixed without shipping an app update — which matters
/// far more on iOS, where a release takes days of review.
///
/// Currently consumes `streamPatterns`: host → regex identifying that site's
/// stream URLs. The sniffer applies the entry matching the frame's hostname.
enum ManifestStore {
    private static let url = URL(string: "https://panura.pages.dev/player/manifest.json")!
    private static let ttl: TimeInterval = 6 * 60 * 60   // Android refreshes every 6h
    private static let cacheFile = "manifest.json"
    private static let lastFetchKey = "manifest_last_fetch"

    /// host → regex string, ready to serialize into the page.
    static func streamPatterns() async -> [String: String] {
        guard let data = await load() else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["streamPatterns"] as? [String: Any] else { return [:] }

        var out: [String: String] = [:]
        for (host, value) in raw {
            // Entries are either {"pattern": "...", "type": "hls"} or a bare string.
            if let dict = value as? [String: Any], let pattern = dict["pattern"] as? String {
                out[host] = pattern
            } else if let pattern = value as? String {
                out[host] = pattern
            }
        }
        return out
    }

    /// JSON object literal for injection, or nil when there's nothing to inject.
    static func streamPatternsJSON() async -> String? {
        let patterns = await streamPatterns()
        guard !patterns.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: patterns),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    // MARK: fetch + cache

    private static func load() async -> Data? {
        let cacheURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheFile)

        let age = Date().timeIntervalSince1970
            - UserDefaults.standard.double(forKey: lastFetchKey)
        if age < ttl, let cached = try? Data(contentsOf: cacheURL) {
            return cached
        }

        if let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            try? data.write(to: cacheURL)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastFetchKey)
            return data
        }
        return try? Data(contentsOf: cacheURL)   // stale fallback
    }
}
