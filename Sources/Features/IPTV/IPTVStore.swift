import Foundation

/// A playlist somebody pays for, as they entered it.
///
/// Three ways in, two code paths.
///
/// - **M3U** — one long URL with the credentials already in its query. Older
///   providers, and anything somebody assembled themselves.
/// - **Xtream** — server, username, password. The API nearly every panel
///   speaks.
/// - **Dispatcharr** — the same API. Dispatcharr's output modes are M3U,
///   XMLTV, Xtream Codes and HDHomeRun, so a Dispatcharr box *is* an Xtream
///   server here.
///
/// Dispatcharr is a separate choice anyway, and that is a deliberate piece of
/// duplication. Somebody running one is looking for the word "Dispatcharr";
/// making them work out that it is Xtream underneath is making them do our
/// filing. The code behind the two is one client — see `usesXtream`.
///
/// Signing in beats an M3U wherever it is offered: the panel hands over
/// categories as names rather than numbers, says when the subscription
/// expires, and costs two small JSON calls instead of a multi-megabyte
/// download.
struct IPTVSource: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case m3u, xtream, dispatcharr
        var id: String { rawValue }

        /// Both of these talk to the same client.
        var usesXtream: Bool { self != .m3u }

        var label: String {
            switch self {
            case .m3u: return "M3U"
            case .xtream: return "Xtream"
            case .dispatcharr: return "Dispatcharr"
            }
        }

        var detail: String {
            switch self {
            case .m3u:
                return "The single playlist address your provider sent you"
            case .xtream:
                return "Xtream Codes panel — server, username and password"
            case .dispatcharr:
                return "Your own Dispatcharr server and its sign-in"
            }
        }

        /// Under the fields, where the wording has to differ even though the
        /// request does not.
        var help: String {
            switch self {
            case .m3u:
                return ""
            case .xtream:
                return "The server is the part before the username, like http://example.com:8080. The password is kept in the iOS keychain on this device."
            case .dispatcharr:
                return "The address of your Dispatcharr server, like http://192.168.1.10:9191, and the username and password of a Dispatcharr user. Panura uses its Xtream Codes output. The password is kept in the iOS keychain on this device."
            }
        }
    }

    var id: UUID = UUID()
    var name: String = ""
    var kind: Kind = .xtream
    /// The M3U address, for `.m3u`.
    var address: String = ""
    /// The panel, for `.xtream`. Scheme and port optional — see
    /// `XtreamClient.normalised`.
    var host: String = ""
    var username: String = ""

    /// Where the password is kept. The record never holds one.
    var credentialKey: String { "iptv." + id.uuidString }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let source = kind.usesXtream ? (XtreamClient.normalised(host) ?? "") : address
        return URL(string: source)?.host ?? "Playlist"
    }

    /// What the row under the name shows. Never the password, and for an M3U
    /// never the query either — that *is* the credentials.
    var subtitle: String {
        guard kind.usesXtream else {
            guard let url = URL(string: address), let host = url.host else { return address }
            return host + url.path
        }
        let server = XtreamClient.normalised(host) ?? host
        return username.isEmpty ? server : "\(username) · \(server)"
    }

    var isComplete: Bool {
        guard kind.usesXtream else {
            return url != nil && !address.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return XtreamClient.normalised(host) != nil && !username.isEmpty
    }

    var url: URL? { URL(string: address.trimmingCharacters(in: .whitespaces)) }

    init() {}

    /// Every field optional on the way in.
    ///
    /// The synthesised decoder requires a key for every non-optional property
    /// whatever default it was given, so adding one field to this struct throws
    /// on every record written before it existed — and because these are
    /// decoded as an array, one bad record loses the lot. Somebody who added a
    /// playlist yesterday would have opened the app today to find it gone.
    /// Written out once here, and the next field added costs nothing.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .m3u
        address = try values.decodeIfPresent(String.self, forKey: .address) ?? ""
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
    }
}

/// The playlists, their channels, and how old the channels are.
///
/// **The list is cached and re-read rather than re-fetched.** A provider's M3U
/// is commonly several megabytes and ten thousand channels; pulling it on every
/// launch is somebody's data allowance spent to learn nothing changed. The
/// downloaded text is kept in Caches and re-parsed, which takes milliseconds,
/// and only goes back to the network when it is older than `freshness` or the
/// user asks.
///
/// Caches rather than Documents on purpose: it is somebody else's data, it can
/// always be fetched again, and iOS is welcome to delete it under pressure.
@MainActor
final class IPTVStore: ObservableObject {
    static let shared = IPTVStore()

    @Published private(set) var sources: [IPTVSource] = []
    /// The playlist being looked at, or nil for the list of playlists.
    @Published private(set) var open: IPTVSource?
    @Published private(set) var channels: [M3UChannel] = []
    @Published private(set) var movies: [M3UChannel] = []
    @Published private(set) var series: [XtreamSeries] = []
    /// Which of the three lists is on screen.
    @Published var section: Section = .live
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?
    /// When the open playlist's channels were downloaded.
    @Published private(set) var fetchedAt: Date?
    /// What the panel said about the subscription, when it was asked.
    @Published private(set) var account: XtreamClient.Account?

    /// What a panel carries. An M3U address has only the first.
    enum Section: String, CaseIterable, Identifiable {
        case live, movies, series
        var id: String { rawValue }

        var label: String {
            switch self {
            case .live: return "Live"
            case .movies: return "Movies"
            case .series: return "Series"
            }
        }
    }

    /// Three hours. Long enough that a normal evening never refetches, short
    /// enough that a provider's overnight changes are picked up next day.
    static let freshness: TimeInterval = 3 * 60 * 60

    private static let key = "iptv_sources"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([IPTVSource].self, from: data)
        else { return }
        sources = saved
    }

    var isStale: Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > Self.freshness
    }

    /// The rows the section on screen is made of.
    var listed: [M3UChannel] { section == .movies ? movies : channels }

    /// Whether this account has films and series at all. An M3U address is a
    /// channel list and nothing else, so the switcher does not appear for one.
    var hasCatalogue: Bool { open?.kind.usesXtream == true }

    /// Every group name in the section on screen, in the order they first
    /// appear.
    var groups: [String] {
        var seen: [String] = []
        let names: [String?] = section == .series
            ? series.map(\.group)
            : listed.map(\.group)
        for group in names {
            if let group, !group.isEmpty, !seen.contains(group) { seen.append(group) }
        }
        return seen
    }

    // MARK: playlists

    func save(_ source: IPTVSource) {
        if let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i] = source
        } else {
            sources.append(source)
        }
        persist()
    }

    func password(for source: IPTVSource) -> String {
        Keychain.get(source.credentialKey)
    }

    func save(_ source: IPTVSource, password: String) {
        Keychain.set(password, for: source.credentialKey)
        save(source)
    }

    func remove(_ source: IPTVSource) {
        sources.removeAll { $0.id == source.id }
        for section in Section.allCases {
            try? FileManager.default.removeItem(at: Self.cacheURL(source, section: section))
        }
        Keychain.remove(source.credentialKey)
        if open?.id == source.id { close() }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    // MARK: channels

    func close() {
        open = nil
        channels = []
        movies = []
        series = []
        section = .live
        failure = nil
        fetchedAt = nil
        account = nil
    }

    /// Films or series, fetched the first time somebody asks to see them.
    ///
    /// A panel's film catalogue is routinely larger than its channel list, so
    /// pulling both on sign-in would make every launch pay for something most
    /// sessions never open. Cached under their own names, on the same three
    /// hours as the channels.
    func loadSection(_ wanted: Section) async {
        section = wanted
        guard let source = open, source.kind.usesXtream else { return }
        switch wanted {
        case .live:
            return
        case .movies where !movies.isEmpty:
            return
        case .series where !series.isEmpty:
            return
        default:
            break
        }

        if wanted == .movies, let cached = Self.readCache(source, section: .movies),
           Date().timeIntervalSince(cached.at) < Self.freshness {
            movies = StreamModel.parse(cached.text, base: cached.base)
            return
        }

        isLoading = true
        defer { isLoading = false }
        failure = nil

        let password = password(for: source)
        do {
            if wanted == .movies {
                let found = try await XtreamClient.movies(
                    host: source.host, username: source.username, password: password
                )
                movies = found
                Self.writeCache(source, section: .movies, text: XtreamClient.m3u(found))
            } else {
                series = try await XtreamClient.series(
                    host: source.host, username: source.username, password: password
                )
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? "Could not load that list."
        }
    }

    /// The seasons of one series. Never cached — it is one small call, and a
    /// stale episode list is the kind of wrong nobody forgives.
    func episodes(of show: XtreamSeries) async -> [XtreamSeason] {
        guard let source = open, source.kind.usesXtream else { return [] }
        return (try? await XtreamClient.episodes(
            host: source.host,
            username: source.username,
            password: password(for: source),
            seriesID: show.id
        )) ?? []
    }

    /// Opens a playlist from cache when the cache is young enough, and from the
    /// network when it is not.
    func load(_ source: IPTVSource, force: Bool = false) async {
        open = source
        failure = nil

        if !force, let cached = Self.readCache(source) {
            channels = StreamModel.parse(cached.text, base: cached.base)
            fetchedAt = cached.at
            if !isStale { return }
            // Stale but usable: show it immediately and refresh underneath.
            // A channel list that is three hours old is still a channel list,
            // and staring at a spinner is worse than watching last night's.
        }

        isLoading = true
        defer { isLoading = false }

        if source.kind.usesXtream {
            await signIn(source)
            return
        }

        guard let url = source.url else {
            failure = "That address is not valid."
            return
        }

        var request = URLRequest(url: url)
        // Generous: these files are large and the servers behind them are not
        // always quick.
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            if channels.isEmpty { failure = "Could not reach that playlist." }
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            // 401 and 403 are the common ones and they mean something specific:
            // the subscription, not the address.
            if channels.isEmpty {
                failure = http.statusCode == 401 || http.statusCode == 403
                    ? "The provider refused that playlist. The subscription may have expired."
                    : "The provider answered with an error (\(http.statusCode))."
            }
            return
        }

        let text = String(decoding: data, as: UTF8.self)
        let parsed = StreamModel.parse(text, base: url)
        guard !parsed.isEmpty else {
            if channels.isEmpty {
                failure = "That address did not contain a channel list."
            }
            return
        }

        channels = parsed
        fetchedAt = Date()
        Self.writeCache(source, text: text)
    }

    /// The Xtream path: two JSON calls instead of a download.
    ///
    /// The result is cached as an M3U so both kinds of account share one cache
    /// format and one way back out of it — and so the cache is a file somebody
    /// can open and read if a channel ever goes missing.
    private func signIn(_ source: IPTVSource) async {
        do {
            let result = try await XtreamClient.load(
                host: source.host,
                username: source.username,
                password: password(for: source)
            )
            channels = result.channels
            account = result.account
            fetchedAt = Date()
            Self.writeCache(source, text: XtreamClient.m3u(result.channels))
        } catch {
            // Only when there is nothing on screen. A refresh that fails over a
            // list already showing should leave the list alone.
            if channels.isEmpty {
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "Could not sign in to that server."
            }
        }
    }

    // MARK: cache

    private struct Cached {
        let text: String
        let base: URL
        let at: Date
    }

    private static func cacheURL(_ source: IPTVSource, section: Section = .live) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let suffix = section == .live ? "" : "-" + section.rawValue
        return caches.appendingPathComponent("iptv-\(source.id.uuidString)\(suffix).m3u")
    }

    private static func readCache(_ source: IPTVSource, section: Section = .live) -> Cached? {
        let file = cacheURL(source, section: section)
        // An Xtream cache holds absolute URLs, so the base is only ever used by
        // the M3U kind — where a relative entry is still legal.
        let base = source.kind.usesXtream
            ? URL(string: XtreamClient.normalised(source.host) ?? "")
            : source.url
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let base
        else { return nil }
        // The file's own modification date is the timestamp — no second record
        // to write, and none to fall out of step with the file it describes.
        let at = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate])
            as? Date
        return Cached(text: text, base: base, at: at ?? .distantPast)
    }

    private static func writeCache(
        _ source: IPTVSource, section: Section = .live, text: String
    ) {
        try? text.write(to: cacheURL(source, section: section), atomically: true, encoding: .utf8)
    }
}
