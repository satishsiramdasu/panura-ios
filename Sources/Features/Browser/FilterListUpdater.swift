import WebKit
import Foundation
import ContentBlockerConverter

/// Full ad-block pipeline — the iOS parity for Android's daily EasyList/uBlock
/// fetch. Fetches the same filter lists (24h cache), converts each ABP list to
/// Safari content-blocker JSON via AdGuard's SafariConverterLib, and compiles
/// each into its own WKContentRuleList (one-per-list keeps every list under
/// WebKit's 150k-rule cap; a webview can carry several). The static base list +
/// oisd domains form one more list. Compiled lists persist on disk, so a fresh
/// (<24h) launch just re-attaches them without refetch/reconvert.
///
/// Not portable to iOS (declarative rules can only block/hide, never rewrite):
/// scriptlets (`+js`), `$redirect`, `$removeparam`, `$csp`. The injected
/// `AdBlockScript` covers the most important scriptlet case (pop/pop-under kill).
enum FilterListUpdater {
    private static let ttl: TimeInterval = 24 * 60 * 60
    private static let lastFetchKey = "adblock_last_fetch"
    private static let oisdURL = URL(string: "https://small.oisd.nl/domainswild")!

    /// Same lists Android loads (ExtractorScriptManager.FILTER_LISTS).
    private static let abpLists: [(id: String, file: String, url: String)] = [
        ("easylist",       "easylist.txt",       "https://easylist.to/easylist/easylist.txt"),
        ("easyprivacy",    "easyprivacy.txt",    "https://easylist.to/easylist/easyprivacy.txt"),
        ("ubo-filters",    "ubo-filters.txt",    "https://ublockorigin.github.io/uAssets/filters/filters.min.txt"),
        ("ubo-privacy",    "ubo-privacy.txt",    "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt"),
        ("ubo-badware",    "ubo-badware.txt",    "https://ublockorigin.github.io/uAssets/filters/badware.min.txt"),
        ("adguard-mobile", "adguard-mobile.txt", "https://filters.adtidy.org/extension/ublock/filters/11.txt"),
    ]

    /// All rule lists to attach to the browser.
    static func current() async -> [WKContentRuleList] {
        let stale = Date().timeIntervalSince1970
            - UserDefaults.standard.double(forKey: lastFetchKey) >= ttl

        var lists: [WKContentRuleList] = []

        // 1) Static base + daily oisd domains.
        if let base = await baseList(stale: stale) { lists.append(base) }

        // 2) Converted EasyList/uBlock lists, one WKContentRuleList each.
        for item in abpLists {
            let id = "panura-\(item.id)"
            if !stale, let cached = await ContentBlocker.cached(identifier: id) {
                lists.append(cached)
                continue
            }
            if let text = await fetchText(file: item.file, url: item.url, forceRefresh: stale),
               let compiled = await convertAndCompile(id: id, abpText: text) {
                lists.append(compiled)
            } else if let cached = await ContentBlocker.cached(identifier: id) {
                lists.append(cached) // fetch/convert failed → keep the last good one
            }
        }

        if stale, !lists.isEmpty {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastFetchKey)
        }
        return lists
    }

    // MARK: base list (static hosts + oisd)

    private static func baseList(stale: Bool) async -> WKContentRuleList? {
        if !stale, let cached = await ContentBlocker.cached(identifier: ContentBlocker.baseIdentifier) {
            return cached
        }
        let oisd = await loadOisdDomains(forceRefresh: stale)
        return await ContentBlocker.compile(
            identifier: ContentBlocker.baseIdentifier, extraHosts: oisd
        )
    }

    // MARK: ABP conversion

    private static func convertAndCompile(id: String, abpText: String) async -> WKContentRuleList? {
        // Conversion is CPU-heavy; keep it off the main actor.
        let json = await Task.detached(priority: .utility) { () -> String in
            let rules = abpText.split(separator: "\n").map(String.init)
            let result = ContentBlockerConverter().convertArray(
                rules: rules,
                advancedBlocking: false,
                maxJsonSizeBytes: nil,
                progress: nil
            )
            return result.safariRulesJSON
        }.value
        return await ContentBlocker.compileJSON(identifier: id, json: json)
    }

    // MARK: fetch + cache

    private static func fetchText(file: String, url: String, forceRefresh: Bool) async -> String? {
        let cacheURL = cacheFile(file)
        if !forceRefresh, let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
            return text
        }
        if let remote = URL(string: url),
           let (data, response) = try? await URLSession.shared.data(from: remote),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let text = String(data: data, encoding: .utf8) {
            try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
            return text
        }
        return try? String(contentsOf: cacheURL, encoding: .utf8) // stale fallback
    }

    private static func loadOisdDomains(forceRefresh: Bool) async -> [String] {
        guard let text = await fetchText(
            file: "oisd_small.txt", url: oisdURL.absoluteString, forceRefresh: forceRefresh
        ) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), !t.hasPrefix("!") else { return nil }
            return t.hasPrefix("*.") ? String(t.dropFirst(2)) : t
        }
    }

    private static func cacheFile(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }
}
