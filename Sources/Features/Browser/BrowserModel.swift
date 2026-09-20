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

    /// Silences the page while the player is up, and lets it play again after.
    /// Autoplay is on, and the play-click script may just have started the
    /// page's own video; left running under the player, its audio takes the
    /// session and AVPlayer opens paused.
    @MainActor
    func suspendPageMedia(_ suspended: Bool) {
        guard let webView else { return }
        if suspended { webView.pauseAllMediaPlayback(completionHandler: nil) }
        webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        // The stored default decides which UA a fresh web view starts on; the
        // browser menu still flips a single session from under it.
        if UserDefaults.standard.bool(forKey: "desktop_mode_default") {
            desktopMode = true
            webView.customUserAgent = Self.desktopUA
        }
    }

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

    /// Private browsing lives on `BrowserSession`, not here: Home's address
    /// pill toggles it too, and that view owns no web view. This is the
    /// browser's own read of it.
    var privateMode: Bool { BrowserSession.shared.privateMode }

    /// The caller rebuilds the web view (a data store cannot be swapped on a
    /// live one); this only has to say what the mode is and drop the findings
    /// that belonged to the session being thrown away.
    func setPrivateMode(_ on: Bool) {
        guard BrowserSession.shared.privateMode != on else { return }
        BrowserSession.shared.setPrivateMode(on)
        clearFindings()
    }

    func toggleDesktopMode() { setDesktopMode(!desktopMode) }

    func setDesktopMode(_ on: Bool) {
        guard desktopMode != on else { return }
        desktopMode = on
        webView?.customUserAgent = on ? Self.desktopUA : nil
        reload()
    }

    /// Turns ad blocking on or off for the page that is open.
    ///
    /// Rule lists can be added to and removed from a live content controller,
    /// which is the whole reason this one setting can be per-site while the
    /// script-based ones cannot — see `SiteSettings`. The reload is not
    /// optional: rules are applied as resources are requested, so a page that
    /// has already loaded is unaffected until it asks again.
    func applyAdBlock(_ on: Bool) {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        guard on else {
            controller.removeAllContentRuleLists()
            webView.reload()
            return
        }
        Task { @MainActor in
            for list in await FilterListUpdater.current() {
                controller.add(list)
            }
            webView.reload()
        }
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
        ruleMatched: Bool = false,
        source: DetectionSource = .unknown
    ) {
        // Detection turned off for this site: the scripts still run — they are
        // registered when the web view is built — but nothing they find is
        // kept, which is what the switch promises.
        guard SiteSettings.shared.value(.detection, host: SiteSettings.key(for: currentURL))
        else { return }
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
            source: source,
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
