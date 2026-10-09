import Foundation

/// A playlist somebody pays for, as they entered it.
///
/// One URL. Providers hand out a single address with the credentials already in
/// its query, so a separate username and password would be two fields nobody
/// has anything to put in. A provider that genuinely wants HTTP basic auth can
/// have it the same way — `https://user:pass@host/get.php?…` is a valid URL.
struct IPTVSource: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var address: String = ""

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: address)?.host ?? "Playlist"
    }

    var url: URL? { URL(string: address.trimmingCharacters(in: .whitespaces)) }
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
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?
    /// When the open playlist's channels were downloaded.
    @Published private(set) var fetchedAt: Date?

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

    /// Every group name in the open playlist, in the order they first appear.
    var groups: [String] {
        var seen: [String] = []
        for channel in channels {
            if let group = channel.group, !group.isEmpty, !seen.contains(group) {
                seen.append(group)
            }
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

    func remove(_ source: IPTVSource) {
        sources.removeAll { $0.id == source.id }
        try? FileManager.default.removeItem(at: Self.cacheURL(source))
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
        failure = nil
        fetchedAt = nil
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

        guard let url = source.url else {
            failure = "That address is not valid."
            return
        }

        isLoading = true
        defer { isLoading = false }

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

    // MARK: cache

    private struct Cached {
        let text: String
        let base: URL
        let at: Date
    }

    private static func cacheURL(_ source: IPTVSource) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("iptv-\(source.id.uuidString).m3u")
    }

    private static func readCache(_ source: IPTVSource) -> Cached? {
        let file = cacheURL(source)
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let base = source.url
        else { return nil }
        // The file's own modification date is the timestamp — no second record
        // to write, and none to fall out of step with the file it describes.
        let at = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate])
            as? Date
        return Cached(text: text, base: base, at: at ?? .distantPast)
    }

    private static func writeCache(_ source: IPTVSource, text: String) {
        try? text.write(to: cacheURL(source), atomically: true, encoding: .utf8)
    }
}
