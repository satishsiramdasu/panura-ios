import CryptoKit
import Foundation

/// Frames captured for the Continue Watching row.
///
/// Caches rather than Documents: these are regenerated the next time an item
/// plays, so they must not count against the user's storage or be backed up.
/// Every read therefore has to tolerate the file having vanished.
enum ResumeThumbnails {
    static var directory: URL {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("resume-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Hashed rather than derived from the URL: stream URLs carry query strings
    /// and tokens that are neither filename-safe nor length-bounded.
    static func path(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return directory.appendingPathComponent("\(name).jpg").path
    }

    static func remove(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A site the user pinned (bookmark) or visited (history). One shape for both —
/// the two lists differ only in how they are ordered and trimmed.
struct SiteEntry: Codable, Identifiable, Hashable {
    var url: String
    var title: String
    var visits: Int = 1
    var lastVisit: Date = .init()
    /// The page's own artwork, when whoever saved the entry knew it. Optional
    /// rather than defaulted, because the synthesised decoder reads an Optional
    /// with `decodeIfPresent` and so keeps reading entries written before this
    /// property existed; a non-optional with a default would throw on all of
    /// them and empty every list on first launch after the update.
    var poster: String?
    /// The second answer, for a page that gave two and whose first one does not
    /// load. Saved alongside rather than resolved at save time: which of the
    /// two works is something only a fetch can decide, and the entry is written
    /// from a tap that must not wait on the network.
    var posterAlt: String?
    /// A video in this phone's library rather than a page on the web, in which
    /// case `url` is the Photos local identifier. Optional for the same reason
    /// `poster` is: entries written before this existed must still decode.
    var isLocal: Bool?

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

/// Per-host tally behind Most Visited, kept apart from the per-URL history the
/// way browsers do it: history answers "which page did I open", top sites
/// answers "which site do I use". One store cannot answer both — key it by URL
/// and every page becomes its own tile; key it by host and the recents list
/// collapses to one row per site.
///
/// `label` is the site's name, not the last page's title. See `recordVisit`.
struct HostVisit: Codable, Identifiable, Hashable {
    var host: String
    var label: String
    var visits: Int = 1
    var lastVisit: Date = .init()

    var id: String { host }

    /// Rendered through the same `SiteEntry` row as everything else on Home.
    var asEntry: SiteEntry {
        SiteEntry(url: "https://\(host)/", title: label, visits: visits, lastVisit: lastVisit)
    }
}

/// Where a video was left, keyed by its URL.
///
/// The position lives in `UserDefaults` rather than in `ResumeEntry`, because
/// the player resumes anything it is handed — a video opened from the browser
/// or the library resumes whether or not it has a Home card. Home's entry and
/// this key are written together and have to be forgotten together: dropping
/// the card while leaving the key behind meant "Remove" did not actually
/// forget the position, and replaying the same URL still jumped mid-film.
enum ResumePosition {
    /// Stable across launches — `String.hashValue` is per-process seeded, so it
    /// must NOT be used here or cross-session resume never matches.
    static func key(_ url: String) -> String { "resume_" + url }

    static func seconds(_ url: String) -> Double {
        UserDefaults.standard.double(forKey: key(url))
    }

    static func save(_ seconds: Double, for url: String) {
        UserDefaults.standard.set(seconds, forKey: key(url))
    }

    static func forget(_ url: String) {
        UserDefaults.standard.removeObject(forKey: key(url))
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
    /// Frame grabbed during playback. Optional on purpose — it lives in Caches,
    /// so the system may evict it at any time and the card falls back to a glyph.
    var thumbnailPath: String?

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

/// Home-screen state that outlives a launch: bookmarks, visit history (which
/// feeds Most Visited) and continue-watching. Mirrors what Android keeps in Room
/// — small enough here that UserDefaults JSON is the whole storage layer.
@MainActor
final class BrowsingStore: ObservableObject {
    static let shared = BrowsingStore()

    @Published private(set) var bookmarks: [SiteEntry] = []
    /// Pages set aside to watch later.
    ///
    /// The PAGE, never the stream. A detected stream URL is signed and expires
    /// in hours - which is what `pruneDeadResumes()` exists to clean up after -
    /// so a list that stored one would be a list of dead links by morning.
    /// Storing the page means opening an entry runs detection again, on
    /// whatever the site serves that day.
    @Published private(set) var watchLater: [SiteEntry] = []
    /// Per-URL, as a browser's history is: every distinct page is its own row.
    @Published private(set) var history: [SiteEntry] = []
    /// Per-host, feeding Most Visited. Deliberately not capped to the history
    /// window, so a site you use constantly survives a burst of other browsing.
    @Published private(set) var hostVisits: [HostVisit] = []
    @Published private(set) var resumes: [ResumeEntry] = []

    /// Off (incognito, or the user cleared it) suppresses history writes only —
    /// bookmarks and resume points are explicit user actions and still persist.
    @Published var recordHistory = true

    private let watchLaterKey = "home_watch_later"
    private let bookmarksKey = "home_bookmarks"
    /// What the same list was called when bookmarks were called shortcuts. Read
    /// once, at first launch after the rename, so nobody loses a saved site to
    /// a change of vocabulary; written back under the new key immediately, and
    /// never read again after that.
    private let legacyBookmarksKey = "home_shortcuts"
    private let historyKey = "home_history"
    private let hostVisitsKey = "home_host_visits"
    private let resumeKey = "home_resume"

    private let historyLimit = 300
    private let hostVisitLimit = 60
    private let resumeLimit = 30

    /// Last URL passed to `recordVisit`, so the browser's two calls per page
    /// (URL first, title once it lands) count as a single visit.
    private var lastRecordedURL: String?

    private init() {
        if let saved: [SiteEntry] = Self.load(bookmarksKey) {
            bookmarks = saved
        } else if let inherited: [SiteEntry] = Self.load(legacyBookmarksKey) {
            bookmarks = inherited
            Self.save(inherited, bookmarksKey)
            UserDefaults.standard.removeObject(forKey: legacyBookmarksKey)
        }
        history = Self.load(historyKey) ?? []
        watchLater = Self.load(watchLaterKey) ?? []
        resumes = Self.load(resumeKey) ?? []
        hostVisits = Self.load(hostVisitsKey) ?? Self.seedHostVisits(from: history)
    }

    /// First run after the split: derive the tally from whatever history the
    /// install already has, so Most Visited is populated rather than empty.
    private static func seedHostVisits(from entries: [SiteEntry]) -> [HostVisit] {
        var merged: [String: HostVisit] = [:]
        for entry in entries {
            let key = entry.host
            guard var existing = merged[key] else {
                merged[key] = HostVisit(
                    host: key,
                    label: entry.title.isEmpty ? key : entry.title,
                    visits: entry.visits,
                    lastVisit: entry.lastVisit
                )
                continue
            }
            existing.visits += entry.visits
            existing.lastVisit = max(existing.lastVisit, entry.lastVisit)
            if existing.label == key, !entry.title.isEmpty, entry.title != key {
                existing.label = entry.title
            }
            merged[key] = existing
        }
        return Array(merged.values)
    }

    // MARK: derived lists

    /// One tile per site, most-visited first; ties broken by recency so a fresh
    /// install still ranks. Drawn from the host tally, not from history — that
    /// is the whole point of keeping the two apart.
    var mostVisited: [SiteEntry] {
        hostVisits
            .sorted { $0.visits == $1.visits ? $0.lastVisit > $1.lastVisit : $0.visits > $1.visits }
            .map(\.asEntry)
    }

    /// Per-page, newest first — the address bar wants the actual page you were
    /// on, not the site it belonged to.
    var recentlyVisited: [SiteEntry] {
        history.sorted { $0.lastVisit > $1.lastVisit }
    }

    var continueWatching: [ResumeEntry] {
        resumes.sorted { $0.updated > $1.updated }
    }

    // MARK: bookmarks

    func isBookmark(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    func addBookmark(url: String, title: String) {
        guard !url.isEmpty, !isBookmark(url) else { return }
        bookmarks.append(SiteEntry(url: url, title: title.isEmpty ? url : title))
        persistBookmarks()
    }

    func removeBookmark(url: String) {
        bookmarks.removeAll { $0.url == url }
        persistBookmarks()
    }

    func updateBookmark(original: String, title: String, url: String) {
        guard let i = bookmarks.firstIndex(where: { $0.url == original }) else { return }
        bookmarks[i].title = title
        bookmarks[i].url = url
        persistBookmarks()
    }

    func moveBookmarks(from source: IndexSet, to destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        persistBookmarks()
    }

    // MARK: watch later

    func isWatchLater(_ url: String) -> Bool {
        watchLater.contains { $0.url == url }
    }

    /// Newest first: this is a queue of intentions, and the one just added is
    /// the one being thought about.
    func addWatchLater(
        url: String,
        title: String,
        poster: String? = nil,
        posterAlt: String? = nil,
        isLocal: Bool = false
    ) {
        guard !url.isEmpty else { return }
        watchLater.removeAll { $0.url == url }
        watchLater.insert(
            SiteEntry(
                url: url,
                title: title.isEmpty ? url : title,
                poster: poster,
                posterAlt: posterAlt,
                isLocal: isLocal ? true : nil
            ),
            at: 0
        )
        persistWatchLater()
    }

    func removeWatchLater(url: String) {
        watchLater.removeAll { $0.url == url }
        persistWatchLater()
    }

    func moveWatchLater(from source: IndexSet, to destination: Int) {
        watchLater.move(fromOffsets: source, toOffset: destination)
        persistWatchLater()
    }

    func clearWatchLater() {
        watchLater.removeAll()
        persistWatchLater()
    }

    // MARK: history

    /// One page view. Repeat visits to the same URL bump the counter rather than
    /// adding a row, which is what makes Most Visited meaningful. The browser
    /// calls this twice per page (URL first, title once WebKit has it), so a
    /// repeat of the URL just landed on only refreshes the title.
    func recordVisit(url: URL, title: String) {
        guard recordHistory else { return }
        guard let scheme = url.scheme, scheme.hasPrefix("http"), let rawHost = url.host else { return }

        let key = url.absoluteString
        let isRestatement = key == lastRecordedURL
        lastRecordedURL = key

        // History: one row per page, as a browser's history is. The title
        // arrives in a second call once the page reports it, which must refresh
        // the row rather than count another visit.
        if let i = history.firstIndex(where: { $0.url == key }) {
            if !isRestatement { history[i].visits += 1 }
            history[i].lastVisit = Date()
            if !title.isEmpty { history[i].title = title }
        } else {
            history.append(SiteEntry(url: key, title: title.isEmpty ? (url.host ?? key) : title))
        }
        if history.count > historyLimit {
            // Recency alone here: the visit-weighted ranking belongs to the host
            // tally, which is uncapped, so trimming history cannot cost a
            // frequently-used site its tile.
            history = Array(history.sorted { $0.lastVisit > $1.lastVisit }.prefix(historyLimit))
        }
        persistHistory()

        bumpHost(rawHost, title: title, isRoot: url.path.isEmpty || url.path == "/", counts: !isRestatement)
    }

    /// The Most Visited side of a visit.
    ///
    /// `label` deliberately prefers the site's own front page. Taking whichever
    /// title came last renames a site's tile to "Episode 4" or "Player" — the
    /// tile names a site, not the last thing you opened on it. A deep page's
    /// title is still better than nothing, so it fills a placeholder.
    private func bumpHost(_ rawHost: String, title: String, isRoot: Bool, counts: Bool) {
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        guard !host.isEmpty else { return }

        if let i = hostVisits.firstIndex(where: { $0.host == host }) {
            if counts { hostVisits[i].visits += 1 }
            hostVisits[i].lastVisit = Date()
            if !title.isEmpty, title != host, isRoot || hostVisits[i].label == host {
                hostVisits[i].label = title
            }
        } else {
            hostVisits.append(
                HostVisit(host: host, label: title.isEmpty ? host : title)
            )
        }
        if hostVisits.count > hostVisitLimit {
            hostVisits = Array(
                hostVisits.sorted {
                    $0.visits == $1.visits ? $0.lastVisit > $1.lastVisit : $0.visits > $1.visits
                }.prefix(hostVisitLimit)
            )
        }
        persistHostVisits()
    }

    /// Removing one page leaves the site's tile alone — the user dismissed a
    /// row from recents, not a site they use. Dismissing a tile is the separate
    /// `removeHostVisit`.
    func removeHistory(url: String) {
        history.removeAll { $0.url == url }
        persistHistory()
    }

    func removeHostVisit(host: String) {
        hostVisits.removeAll { $0.host == host }
        persistHostVisits()
    }

    /// "Clear history" means both, as it does in a browser: leaving the tiles
    /// behind would still show where the user had been.
    func clearHistory() {
        history.removeAll()
        hostVisits.removeAll()
        persistHistory()
        persistHostVisits()
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

    /// Position update from the player. A finished item drops off the row
    /// instead of sitting there at 100%.
    ///
    /// The three cases below are deliberately separate. Collapsing them into
    /// one "save if in range, else delete" is what emptied the row entirely:
    /// the first tick of every playback arrives with duration still 0 (VLC has
    /// not parsed it) or position under the threshold, so it deleted the entry
    /// `beginWatching` had just created — and the guard then stopped anything
    /// from bringing it back for the rest of the session.
    func updateWatching(url: URL, position: Double, duration: Double) {
        let key = url.absoluteString
        guard let i = resumes.firstIndex(where: { $0.url == key }) else { return }

        // Nothing known yet. Leave the entry alone rather than reading the
        // absence of a duration as "finished".
        guard duration > 0 else { return }

        // Watched to the end — drop it.
        if position >= duration - 15 {
            ResumeThumbnails.remove(resumes[i].thumbnailPath)
            resumes.remove(at: i)
            ResumePosition.forget(key)
            persistResumes()
            return
        }

        // Too early to be worth resuming from, but the item is legitimately
        // being watched: keep it on Home, just without a position, so it starts
        // from the beginning if tapped.
        guard position > 15 else { return }

        resumes[i].position = position
        resumes[i].duration = duration
        resumes[i].updated = Date()
        persistResumes()
    }

    /// Attach a captured frame. Separate from `updateWatching` because the
    /// snapshot lands asynchronously, well after the position that triggered it.
    func setThumbnail(url: URL, path: String) {
        let key = url.absoluteString
        guard let i = resumes.firstIndex(where: { $0.url == key }) else { return }
        resumes[i].thumbnailPath = path
        persistResumes()
    }

    /// Drops the resume entries whose links have died, and answers with how
    /// many went. Called when Home appears.
    ///
    /// Continue Watching remembers a URL, and a browser stream's URL is a
    /// token with an expiry on it — a day later the same address is a 404, and
    /// the card is an invitation to a video that cannot play. A local entry
    /// dies differently: the file it names is a temporary copy of a library
    /// asset, and the system clears those on its own schedule, so the check
    /// there is simply whether the file is still on disk.
    ///
    /// Fail-safe, exactly like `StreamProbe`: a refusal or a network error
    /// keeps the entry. Deleting someone's place in a film because the Wi-Fi
    /// dropped is a far worse failure than showing one dead card.
    @discardableResult
    func pruneDeadResumes() async -> Int {
        let snapshot = resumes
        guard !snapshot.isEmpty else { return 0 }

        var dead: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for entry in snapshot {
                group.addTask { (entry.url, await Self.isAlive(entry)) }
            }
            for await (url, alive) in group where !alive { dead.append(url) }
        }

        for url in dead { removeWatching(url: url) }
        return dead.count
    }

    /// One entry's liveness — the pre-flight check a tap makes, so a dead card
    /// says so instead of opening a player that fails.
    nonisolated static func isAlive(_ entry: ResumeEntry) async -> Bool {
        guard let url = URL(string: entry.url) else { return false }
        if entry.isLocal || url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return await StreamProbe.isAlive(url: url, headers: entry.headers)
    }

    /// Empties Continue Watching. The videos and their files are untouched —
    /// only the resume points go, which is what the confirmation says.
    func clearWatching() {
        for entry in resumes {
            ResumeThumbnails.remove(entry.thumbnailPath)
            ResumePosition.forget(entry.url)
        }
        resumes.removeAll()
        persistResumes()
    }

    func removeWatching(url: String) {
        for entry in resumes where entry.url == url {
            ResumeThumbnails.remove(entry.thumbnailPath)
        }
        resumes.removeAll { $0.url == url }
        // The saved position goes with the card. Without this, removing an
        // entry only hid it: the same URL played again still resumed from where
        // it was, which is not what Remove says it does.
        ResumePosition.forget(url)
        persistResumes()
    }

    private func trimResumes() {
        guard resumes.count > resumeLimit else { return }
        let kept = Array(resumes.sorted { $0.updated > $1.updated }.prefix(resumeLimit))
        // Drop the frames of everything that fell off, or Caches grows forever.
        let keptURLs = Set(kept.map(\.url))
        for entry in resumes where !keptURLs.contains(entry.url) {
            ResumeThumbnails.remove(entry.thumbnailPath)
        }
        resumes = kept
    }

    // MARK: storage

    private func persistBookmarks() { Self.save(bookmarks, bookmarksKey) }
    private func persistWatchLater() { Self.save(watchLater, watchLaterKey) }
    private func persistHistory() { Self.save(history, historyKey) }
    private func persistHostVisits() { Self.save(hostVisits, hostVisitsKey) }
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
