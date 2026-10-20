import Foundation

/// Reads the remote detection manifest so rules can be fixed without shipping an
/// app update — which matters far more on iOS, where a release takes days.
///
/// The deployed manifest names no domains and no longer identifies sites at
/// all. A rule is a URL *shape* plus the handling that shape needs, and it is
/// selected in the page by matching a candidate against its pattern — the way
/// a filter list works. Nothing is looked up by host, so there is nothing to
/// hash and no salt to keep in step across three places.
///
/// What that replaced: `id` used to be a list of HMAC-SHA256 hashes of the
/// rule's hostnames, matched against the frame's own hashed host. It worked,
/// but the salt had to agree between this app, the Android build and the CDN
/// build tool, so re-hashing meant a coordinated release on both platforms
/// rather than a CDN commit. A pattern specific enough to identify a site
/// without naming it — `/hls/<28 base64>(QT09|Zz09|dz09|UT09)/` — does the
/// same job with none of that.
///
/// `id` is still tolerated and ignored, so this reads a v3 file (which carries
/// it) and a host-free one identically. That is deliberate: it means the apps
/// can ship before the CDN changes, with no flag day between them.
enum ManifestStore {
    private static let url = URL(string: "https://panura.app/manifest.json")!
    private static let ttl: TimeInterval = 6 * 60 * 60   // Android refreshes every 6h
    private static let cacheFile = "manifest.json"
    private static let lastFetchKey = "manifest_last_fetch"

    /// Rule entries verbatim. Order preserved — first *pattern* match wins.
    ///
    /// They live under `presets` in the served file: the deployed manifest is
    /// meant to read as ordinary player config, not as a list of targets.
    static func sites() async -> [[String: Any]] {
        guard let data = await load(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sites = root["presets"] as? [[String: Any]] else { return [] }
        return sites
    }

    /// The `ads` block — country-tiered pacing config — or nil if the manifest
    /// hasn't been fetched yet or carries none. Unlike `sites`, nothing here is
    /// hashed: country codes aren't hosts, so there is nothing to hide.
    static func adsConfig() async -> [String: Any]? {
        guard let data = await load(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["ads"] as? [String: Any]
    }

    /// Every rule, with `id` dropped, in manifest order.
    ///
    /// All of them, because which one applies is not knowable until a URL turns
    /// up: the pattern is the selector. `id` is removed rather than read — a v3
    /// file still carries the old hashed host list and it is now dead weight,
    /// and it has no business being handed to a page either way.
    static func rules() async -> [[String: Any]] {
        await sites().map { site in
            var rule = site
            rule.removeValue(forKey: "id")
            return rule
        }
    }

    /// Force the next read to refetch, but keep the cached file as offline
    /// fallback. Called once at launch (see AppDelegate) so a server-side rule
    /// fix is picked up promptly rather than after the 6h TTL.
    static func refreshOnLaunch() {
        UserDefaults.standard.removeObject(forKey: lastFetchKey)
    }

    /// Drop the cached manifest so the next read refetches. Without this,
    /// testing a rule change means waiting out the 6h TTL.
    static func clearCache() {
        UserDefaults.standard.removeObject(forKey: lastFetchKey)
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheFile)
        try? FileManager.default.removeItem(at: url)
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
