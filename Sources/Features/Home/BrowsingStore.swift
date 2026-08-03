import Foundation

/// A site the user pinned (shortcut) or visited (history). One shape for both —
/// the two lists differ only in how they are ordered and trimmed.
struct SiteEntry: Codable, Identifiable, Hashable {
    var url: String
    var title: String
    var visits: Int = 1
    var lastVisit: Date = .init()

    var id: String { url }

    var host: String {
        guard let h = URL(string: url)?.host else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Google's favicon service — same endpoint Android's home grid uses, so the
    /// two platforms show identical icons.
    var faviconURL: URL? {
        URL(string: "https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON"
            + "&fallback_opts=TYPE,SIZE,URL&url=https://\(host)&size=64")
    }
}

/// A partially-watched item, enough to rebuild the `MediaItem` and resume it.
struct ResumeEntry: Codable, Identifiable, Hashable {
    var url: String
    var title: String
    var position: Double = 0
    var duration: Double = 0
    var isLocal: Bool = false
    var headers: [String: String] = [:]
    var contentType: String?
    var updated: Date = .init()

    var id: String { url }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var remainingSeconds: Double { max(duration - position, 0) }

    /// "45s left" · "12m left" · "1h 5m left" — matches Android's chip.
    var timeLeftLabel: String {
        let total = Int(remainingSeconds)
        let minutes = total / 60
        if minutes < 1 { return "\(max(total, 1))s left" }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }

    var mediaItem: MediaItem {
        MediaItem(
            title: title,
            url: URL(string: url) ?? URL(string: "about:blank")!,
            isLocal: isLocal,
            headers: headers,
            contentType: contentType
        )
    }
}

/// Home-screen state that outlives a launch: shortcuts, visit history (which
/// feeds Most Visited) and continue-watching. Mirrors what Android keeps in Room
/// — small enough here that UserDefaults JSON is the whole storage layer.
@MainActor
final class BrowsingStore: ObservableObject {
    static let shared = BrowsingStore()

    @Published private(set) var shortcuts: [SiteEntry] = []
    @Published private(set) var history: [SiteEntry] = []
    @Published private(set) var resumes: [ResumeEntry] = []

    /// Off (incognito, or the user cleared it) suppresses history writes only —
    /// shortcuts and resume points are explicit user actions and still persist.
    @Published var recordHistory = true

    private let shortcutsKey = "home_shortcuts"
    private let historyKey = "home_history"
    private let resumeKey = "home_resume"

    private let historyLimit = 300
    private let resumeLimit = 30

    /// Last URL passed to `recordVisit`, so the browser's two calls per page
    /// (URL, then title) count as one visit.
    private var lastRecordedURL: String?

    private init() {
        shortcuts = Self.load(shortcutsKey) ?? []
        history = Self.load(historyKey) ?? []
        resumes = Self.load(resumeKey) ?? []
    }

    // MARK: derived lists

    /// Most-visited first; ties broken by recency so a fresh install still ranks.
    var mostVisited: [SiteEntry] {
        history.sorted {
            $0.visits == $1.visits ? $0.lastVisit > $1.lastVisit : $0.visits > $1.visits
        }
    }

    var recentlyVisited: [SiteEntry] {
        history.sorted { $0.lastVisit > $1.lastVisit }
    }

    var continueWatching: [ResumeEntry] {
        resumes.sorted { $0.updated > $1.updated }
    }

    // MARK: shortcuts

    func isShortcut(_ url: String) -> Bool {
        shortcuts.contains { $0.url == url }
    }

    func addShortcut(url: String, title: String) {
        guard !url.isEmpty, !isShortcut(url) else { return }
        shortcuts.append(SiteEntry(url: url, title: title.isEmpty ? url : title))
        persistShortcuts()
    }

    func removeShortcut(url: String) {
        shortcuts.removeAll { $0.url == url }
        persistShortcuts()
    }

    func updateShortcut(original: String, title: String, url: String) {
        guard let i = shortcuts.firstIndex(where: { $0.url == original }) else { return }
        shortcuts[i].title = title
        shortcuts[i].url = url
        persistShortcuts()
    }

    func moveShortcuts(from source: IndexSet, to destination: Int) {
        shortcuts.move(fromOffsets: source, toOffset: destination)
        persistShortcuts()
    }

    // MARK: history

    /// One page view. Repeat visits to the same URL bump the counter rather than
    /// adding a row, which is what makes Most Visited meaningful. The browser
    /// calls this twice per page (URL first, title once WebKit has it), so a
    /// repeat of the URL just landed on only refreshes the title.
    func recordVisit(url: URL, title: String) {
        guard recordHistory else { return }
        guard let scheme = url.scheme, scheme.hasPrefix("http") else { return }
        let key = url.absoluteString
        let isRestatement = key == lastRecordedURL
        lastRecordedURL = key
        if let i = history.firstIndex(where: { $0.url == key }) {
            if !isRestatement { history[i].visits += 1 }
            history[i].lastVisit = Date()
            if !title.isEmpty { history[i].title = title }
        } else {
            history.append(SiteEntry(url: key, title: title.isEmpty ? (url.host ?? key) : title))
        }
        if history.count > historyLimit {
            // Drop the least useful: fewest visits, oldest first.
            history = Array(
                history.sorted {
                    $0.visits == $1.visits ? $0.lastVisit > $1.lastVisit : $0.visits > $1.visits
                }.prefix(historyLimit)
            )
        }
        persistHistory()
    }

    func removeHistory(url: String) {
        history.removeAll { $0.url == url }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    // MARK: continue watching

    /// Called when playback starts, so an item shows up on Home even if the user
    /// leaves before the first position save.
    func beginWatching(_ item: MediaItem) {
        let key = item.url.absoluteString
        if let i = resumes.firstIndex(where: { $0.url == key }) {
            resumes[i].updated = Date()
            resumes[i].title = item.title
        } else {
            resumes.append(
                ResumeEntry(
                    url: key,
                    title: item.title,
                    isLocal: item.isLocal,
                    headers: item.headers,
                    contentType: item.contentType
                )
            )
        }
        trimResumes()
        persistResumes()
    }

    /// Position update from the player. A finished item (or one rewound to the
    /// start) drops off the row instead of sitting there at 100%.
    func updateWatching(url: URL, position: Double, duration: Double) {
        let key = url.absoluteString
        guard let i = resumes.firstIndex(where: { $0.url == key }) else { return }
        if duration > 0, position > 15, position < duration - 15 {
            resumes[i].position = position
            resumes[i].duration = duration
            resumes[i].updated = Date()
            persistResumes()
        } else {
            resumes.remove(at: i)
            persistResumes()
        }
    }

    func removeWatching(url: String) {
        resumes.removeAll { $0.url == url }
        persistResumes()
    }

    private func trimResumes() {
        guard resumes.count > resumeLimit else { return }
        resumes = Array(resumes.sorted { $0.updated > $1.updated }.prefix(resumeLimit))
    }

    // MARK: storage

    private func persistShortcuts() { Self.save(shortcuts, shortcutsKey) }
    private func persistHistory() { Self.save(history, historyKey) }
    private func persistResumes() { Self.save(resumes, resumeKey) }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
