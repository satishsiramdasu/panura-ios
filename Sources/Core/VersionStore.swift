import Foundation

/// Reads `version.json` from the CDN — the app versions and changelog Android
/// already reads, split out of the detection manifest on purpose: the two answer
/// different questions, change on different occasions, and want different cache
/// lifetimes. A release must be visible immediately; detection rules are read
/// every few hours.
///
/// Nothing here is hashed. Versions and release notes are public by design —
/// unlike the detection manifest, whose every host is an opaque HMAC.
@MainActor
final class VersionStore: ObservableObject {
    static let shared = VersionStore()

    struct Release: Identifiable, Hashable {
        let versionName: String
        let date: String
        let notes: [String]

        var id: String { versionName }

        /// "2026-08-27" → "27 Aug 2026". Left as-is if it isn't that shape —
        /// this is a label, not a parser worth failing over.
        var displayDate: String {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd"
            iso.locale = Locale(identifier: "en_US_POSIX")
            guard let parsed = iso.date(from: date) else { return date }
            let out = DateFormatter()
            out.dateFormat = "d MMM yyyy"
            return out.string(from: parsed)
        }
    }

    struct Platform {
        let versionCode: Int
        let versionName: String
        let changelog: [Release]
    }

    @Published private(set) var ios: Platform?
    @Published private(set) var isLoading = false

    private static let url = URL(string: "https://panura.app/version.json")!
    private static let cacheFile = "version.json"

    /// The running build, as the two numbers version.json speaks in.
    static var installedVersionName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var installedVersionCode: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// True when the CDN names a build newer than this one. Compared on
    /// `versionCode`, never on the name: names are marketing, codes are ordered.
    var updateAvailable: Bool {
        guard let ios else { return false }
        return ios.versionCode > Self.installedVersionCode
    }

    /// Where an update actually comes from. The App Store is the only channel on
    /// iOS, so unlike Android — which now picks between Play and the Amazon
    /// Appstore by who installed the app — there is nothing to choose.
    ///
    /// The App Store id, assigned when the app record was created in App Store
    /// Connect on 2026-09-15. One constant, so anything that links to the store
    /// has one place to read it from.
    static let appStoreID = "id6812081774"
    static let storeURL = URL(string: "https://apps.apple.com/app/\(appStoreID)")!

    /// False while the id above is still the placeholder.
    ///
    /// A dead App Store link is worse than no link: it appears exactly when the
    /// user has been told an update exists, which is the moment they are least
    /// inclined to forgive it. The row hides itself instead.
    static var storeLinkReady: Bool { appStoreID != "id0000000000" }

    /// Fetches once per launch and then serves what it has. `force` re-fetches —
    /// what "Check for Updates" does, since the point of pressing it is to ask
    /// again rather than to be told what we already knew.
    func load(force: Bool = false) async {
        if ios != nil, !force { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        let cacheURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.cacheFile)

        var data: Data?
        if let (fetched, response) = try? await URLSession.shared.data(from: Self.url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            data = fetched
            try? fetched.write(to: cacheURL)
        } else {
            // Offline, or the CDN is down: the last copy still answers "what did
            // this release change", which is most of what the screen is for.
            data = try? Data(contentsOf: cacheURL)
        }

        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        ios = Self.parse(root["ios"] as? [String: Any])
    }

    private static func parse(_ block: [String: Any]?) -> Platform? {
        guard let block else { return nil }
        let entries = (block["changelog"] as? [[String: Any]] ?? []).compactMap { entry -> Release? in
            guard let name = entry["versionName"] as? String else { return nil }
            return Release(
                versionName: name,
                date: entry["date"] as? String ?? "",
                notes: entry["notes"] as? [String] ?? []
            )
        }
        return Platform(
            versionCode: block["versionCode"] as? Int ?? 0,
            versionName: block["versionName"] as? String ?? "",
            changelog: entries
        )
    }
}
