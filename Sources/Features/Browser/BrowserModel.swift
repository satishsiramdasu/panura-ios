import SwiftUI
import WebKit

@MainActor
final class BrowserModel: ObservableObject {
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var currentURL: URL?
    @Published var pageTitle = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var desktopMode = false
    /// Private browsing. The web view is rebuilt on a non-persistent data store
    /// when this flips (see `BrowserView`), and history recording stops — the
    /// two halves of what "private" has to mean.
    @Published private(set) var privateMode = false
    @Published var foundVideos: [ExtractedVideo] = []
    /// Sidecar subtitles sniffed from the page; attached to whatever the user plays.
    @Published var foundSubtitles: [SubtitleTrack] = []
    /// Title/artwork the site published via MediaSession, when available.
    @Published var mediaSessionTitle = ""
    /// Every media-shaped URL the sniffer saw and what it decided, so a URL that
    /// never reaches `foundVideos` can be told apart from one that was filtered.
    /// Only populated when the Diagnostics setting is on.
    @Published var debugLog: [DebugEntry] = []

    struct DebugEntry: Identifiable, Hashable {
        let id = UUID()
        let url: String
        let verdict: String
        let host: String
        /// Which hook saw it — xhr, fetch, setAttribute, media-event, dom-scan…
        let source: String
    }

    private weak var webView: WKWebView?
    private var seen = Set<String>()
    private var seenSubs = Set<String>()

    /// Desktop UA so sites serve the full site (parity with Android's toggle).
    private static let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func attach(_ webView: WKWebView) { self.webView = webView }

    // MARK: navigation

    func load(_ text: String) {
        let url = Self.normalize(text)
        clearFindings()
        // `#referer=` names the Referer this URL must be fetched with; strip it
        // and send the header. WebKit applies it to this request only — a later
        // in-page navigation carries the page's own referer, same as Android.
        webView?.load(RefererFragment.request(for: url))
    }

    /// Drops the web view's own caches and reloads. Cookies and local storage
    /// are deliberately untouched: one profile serves every site here, so
    /// clearing those would sign the user out everywhere to fix one page.
    func clearCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        WKWebsiteDataStore.default().removeData(
            ofTypes: types, modifiedSince: .distantPast
        ) { [weak self] in
            Task { @MainActor in self?.webView?.reload() }
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { clearFindings(); webView?.reload() }
    func stop() { webView?.stopLoading() }

    /// Turn private browsing on or off.
    ///
    /// The caller rebuilds the web view (a data store cannot be swapped on a
    /// live one), so this only has to say what the mode is and stop — or resume
    /// — history recording. Cookies and cache go with the store; shortcuts and
    /// resume points do not, because those are explicit user actions.
    func setPrivateMode(_ on: Bool) {
        guard privateMode != on else { return }
        privateMode = on
        BrowsingStore.shared.recordHistory = !on
        clearFindings()
    }

    func toggleDesktopMode() {
        desktopMode.toggle()
        webView?.customUserAgent = desktopMode ? Self.desktopUA : nil
        reload()
    }

    /// Findings belong to a page — drop them whenever we navigate.
    func clearFindings() {
        foundVideos.removeAll()
        foundSubtitles.removeAll()
        mediaSessionTitle = ""
        seen.removeAll()
        seenSubs.removeAll()
        debugLog.removeAll()
    }

    func reportDebug(url: String, verdict: String, host: String, source: String) {
        guard debugLog.count < 400 else { return }   // a busy page can flood
        debugLog.append(DebugEntry(url: url, verdict: verdict, host: host, source: source))
    }

    /// The whole log as text, for pasting into a bug report.
    var debugLogText: String {
        debugLog
            .map { "[\($0.host)] \($0.source) -> \($0.verdict)\n\($0.url)" }
            .joined(separator: "\n\n")
    }

    // MARK: detection

    /// Best playable stream first — see `byQuality()`. Everything that shows a
    /// list of detections reads this, and the found-bar speaks for its first
    /// entry, so the stream named on the bar is the one Play would have picked.
    var orderedVideos: [ExtractedVideo] { foundVideos.byQuality() }

    func report(
        url: URL,
        title: String,
        headers: [String: String],
        castHeaders: [String: String] = [:],
        contentType: String? = nil,
        ruleMatched: Bool = false
    ) {
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        let name = title.isEmpty ? mediaSessionTitle : title
        // An embed page has nothing to probe; direct media is probed at once,
        // because the bar wants its quality and size the moment it appears.
        let direct = StreamProbe.isDirectMedia(url) || contentType != nil
        let video = ExtractedVideo(
            url: url, title: name, headers: headers,
            castHeaders: castHeaders.isEmpty ? headers : castHeaders,
            contentType: contentType,
            ruleMatched: ruleMatched,
            probeState: direct ? .pending : .skipped
        )
        foundVideos.append(video)
        if direct { startProbe(video) }
    }

    /// Probes one detection and folds the answer back into its row.
    ///
    /// An inactive result drops the row outright rather than listing it: only
    /// 404/410 reach that state (see `StreamProbe`), so it is proof the link is
    /// gone — and a re-probe could only ever confirm it again.
    private func startProbe(_ video: ExtractedVideo) {
        let key = video.url.absoluteString
        Task { [weak self] in
            let outcome = await StreamProbe.probe(
                url: video.url, headers: video.headers, ruleMatched: video.ruleMatched
            )
            await MainActor.run {
                guard let self,
                      let i = self.foundVideos.firstIndex(where: { $0.url.absoluteString == key })
                else { return }
                guard outcome.active else {
                    self.foundVideos.remove(at: i)
                    self.reportDebug(
                        url: key, verdict: "dropped: probe says gone",
                        host: video.url.host ?? "", source: "probe"
                    )
                    return
                }
                self.foundVideos[i].probeState = .active
                self.foundVideos[i].probeResult = outcome.result
            }
        }
    }

    /// Re-probe everything still listed — the sheet's refresh. Rows go back to
    /// `.pending` so the bar says a check is running rather than showing stale
    /// numbers as if they were fresh.
    func refreshProbes() {
        for i in foundVideos.indices where foundVideos[i].probeState != .skipped {
            foundVideos[i].probeState = .pending
            foundVideos[i].probeResult = nil
            startProbe(foundVideos[i])
        }
    }

    /// Drop one detection by hand. It stays in `seen`, so the same URL sighted
    /// again cannot resurrect the row the user just dismissed.
    func remove(_ video: ExtractedVideo) {
        foundVideos.removeAll { $0.id == video.id }
    }

    /// Drop a hit later proven to be a segment. It stays in `seen` so the same
    /// URL cannot be re-added by a subsequent sighting.
    func retract(url: URL) {
        foundVideos.removeAll { $0.url == url }
    }

    /// A URL reported at request time, whose body later proved it a manifest.
    /// Without this the type stays empty and the player cannot tell libVLC what
    /// a `.txt` playlist served as text/plain actually is.
    func confirmType(url: URL, type: String) {
        guard let i = foundVideos.firstIndex(where: { $0.url == url }) else { return }
        foundVideos[i].contentType = type
    }

    func reportSubtitle(url: URL, label: String, language: String) {
        let key = url.absoluteString
        guard !seenSubs.contains(key) else { return }
        seenSubs.insert(key)
        foundSubtitles.append(SubtitleTrack(url: url, label: label, language: language))
    }

    /// Build the playable item for a detection, carrying page subtitles with it.
    func playable(_ video: ExtractedVideo) -> MediaItem {
        MediaItem(
            title: video.title.isEmpty ? (mediaSessionTitle.isEmpty ? "Video" : mediaSessionTitle) : video.title,
            url: video.url,
            headers: video.headers,
            castHeaders: video.castHeaders,
            subtitles: foundSubtitles,
            contentType: video.contentType
        )
    }

    /// Turn a raw address-bar string into a URL, defaulting to a web search.
    static func normalize(_ text: String) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(" ") || !trimmed.contains(".") {
            let q = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            return URL(string: "https://www.google.com/search?q=\(q)")!
        }
        if trimmed.hasPrefix("http") { return URL(string: trimmed)! }
        return URL(string: "https://\(trimmed)")!
    }
}
