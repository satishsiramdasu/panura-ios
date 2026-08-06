import CryptoKit
import Foundation

/// Reads the remote detection manifest so rules can be fixed without shipping an
/// app update — which matters far more on iOS, where a release takes days.
///
/// The deployed manifest names no domains: each site's `id` IS a list of
/// HMAC-SHA256 hashes of its hostnames — the rule has no readable name at all.
/// We hash the *frame's own* hostname here, natively, and match. The salt
/// (`ManifestSalt`) never enters a web view, so a page can neither read our
/// target list nor brute-force it — and a plain fetch of the manifest is just
/// opaque hashes.
///
/// Schema v3 renamed `h` -> `id` and `stream` -> `pattern`. There is no v2
/// fallback: an unrecognised manifest simply matches nothing, which drops
/// detection to the generic sniffer rather than breaking playback.
enum ManifestStore {
    private static let url = URL(string: "https://panura.app/manifest.json")!
    private static let ttl: TimeInterval = 6 * 60 * 60   // Android refreshes every 6h
    private static let cacheFile = "manifest.json"
    private static let lastFetchKey = "manifest_last_fetch"

    /// Hashed site entries verbatim (each has `id`: [hex hmac], plus optional
    /// type/pattern/referer/headers). Order preserved — first host match wins.
    ///
    /// They live under `presets` in the served file: the deployed manifest is
    /// meant to read as ordinary player config, not as a list of targets.
    static func sites() async -> [[String: Any]] {
        guard let data = await load(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sites = root["presets"] as? [[String: Any]] else { return [] }
        return sites
    }

    /// The rule for `host`, or nil — the first entry whose hashed host list
    /// contains the HMAC of the host or any of its parent domains. Returned
    /// verbatim (still carrying `id`); the caller strips it before use.
    static func rule(forHost host: String) async -> [String: Any]? {
        let sites = await sites()
        guard !sites.isEmpty else { return nil }
        let candidateHashes = Set(hostCandidates(host).map(hash))
        for site in sites {
            if let hashes = site["id"] as? [String],
               hashes.contains(where: candidateHashes.contains) {
                return site
            }
        }
        return nil
    }

    /// HMAC-SHA256(salt, host) as lowercase hex — byte-identical to the Node
    /// build tool (which is why the host must be canonicalised the same way).
    static func hash(_ canonicalHost: String) -> String {
        let key = SymmetricKey(data: Data(ManifestSalt.value.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonicalHost.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// `example.com` and every parent down to two labels, canonicalised to match
    /// the build tool: lowercased, trailing dot removed. Hashing the registrable
    /// domain lets one manifest entry cover every rotating subdomain.
    static func hostCandidates(_ host: String) -> [String] {
        var base = host.lowercased()
        if base.hasSuffix(".") { base.removeLast() }
        var parts = base.split(separator: ".").map(String.init)
        var out: [String] = []
        while parts.count >= 2 {
            out.append(parts.joined(separator: "."))
            parts.removeFirst()
        }
        return out
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
