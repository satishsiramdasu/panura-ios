import SwiftUI
import WebKit

/// Bridges WKWebView into SwiftUI and runs the extraction engine.
///
/// iOS has no `shouldInterceptRequest`. We approximate Android's extraction two ways:
///  1. A JS user-script (`ExtractionScript.js`) injected at document end that scans
///     the DOM / JWPlayer / inline scripts and posts hits back over a message handler.
///  2. A `WKNavigationDelegate` that watches top-level navigations for direct
///     `.m3u8` / `.mp4` URLs.
struct WebViewContainer: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "panura")

        // Ad/pop neutralization first, at document start, so it beats inline
        // pop scripts (window.open, aclib, etc.).
        contentController.addUserScript(WKUserScript(
            source: AdBlockScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        // Video sniffer, also at document start: its fetch/XHR hooks must be
        // installed before page scripts fire their requests, or MSE sites slip
        // through (their DOM only ever exposes a blob: URL). The DOM scan runs
        // on a repeating timer, so starting early costs nothing.
        contentController.addUserScript(WKUserScript(
            source: ExtractionScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Block the pop-under/new-window ads these sites open on tap.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Our own edge gestures drive back/forward, so leave WebKit's off to
        // avoid the two fighting over the same swipe.
        webView.allowsBackForwardNavigationGestures = false
        model.attach(webView)

        // Pull to refresh, like the Android SwipeRefreshLayout.
        let refresh = UIRefreshControl()
        refresh.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refresh
        context.coordinator.observe(webView)
        webView.load(URLRequest(url: URL(string: "https://www.google.com")!))

        // Remote stream patterns + ad/tracker rule lists, then one reload so
        // both apply to the current page.
        Task { @MainActor in
            if let sites = await ManifestStore.sitesJSON() {
                webView.configuration.userContentController.addUserScript(WKUserScript(
                    source: "window.__panuraSites = \(sites);",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                ))
            }
            if let json = await ManifestStore.streamPatternsJSON() {
                webView.configuration.userContentController.addUserScript(WKUserScript(
                    source: "window.__panuraStreamPatternMap = \(json);",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                ))
            }
            let lists = await FilterListUpdater.current()
            for list in lists {
                webView.configuration.userContentController.add(list)
            }
            webView.reload()
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }

        private var observations: [NSKeyValueObservation] = []
        private weak var webView: WKWebView?

        /// Mirror WebKit's navigation state into the model so the toolbar and
        /// the edge gestures know whether back/forward are available.
        func observe(_ webView: WKWebView) {
            self.webView = webView
            observations = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.model.canGoBack = wv.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.model.canGoForward = wv.canGoForward }
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.model.progress = wv.estimatedProgress }
                },
                webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.model.pageTitle = wv.title ?? "" }
                },
            ]
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
        }

        // A page tried to open a new window (target=_blank / window.open) — the
        // usual pop-under ad vector. Load real navigations in the same tab and
        // never spawn the extra window.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, navigationAction.request.url != nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
            model.isLoading = true
            // Main-frame navigation: findings belong to the page we're leaving.
            model.clearFindings()
        }

        func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
            model.isLoading = false
            model.currentURL = webView.url
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
            model.isLoading = false
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation nav: WKNavigation!,
            withError error: Error
        ) {
            model.isLoading = false
            webView.scrollView.refreshControl?.endRefreshing()
        }

        // Catch direct video navigations the JS scan would miss.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url,
               VideoURL.looksLikeVideo(url) {
                // Same context capture as the JS path: the page we're leaving
                // is the Referer the CDN expects.
                var headers: [String: String] = [:]
                if let page = webView.url {
                    headers["Referer"] = page.absoluteString
                    if let scheme = page.scheme, let host = page.host {
                        headers["Origin"] = "\(scheme)://\(host)"
                    }
                }
                if let ua = lastUserAgent { headers["User-Agent"] = ua }
                model.report(url: url, title: webView.title ?? "", headers: headers)
                return .cancel
            }
            return .allow
        }

        /// UA captured from the page, reused for hits found via navigation.
        private var lastUserAgent: String?

        // Hits posted from the injected extraction script.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "panura",
                  let dict = message.body as? [String: Any] else { return }

            switch dict["kind"] as? String {
            case "subtitle":
                if let s = dict["url"] as? String, let u = URL(string: s) {
                    model.reportSubtitle(
                        url: u,
                        label: dict["label"] as? String ?? "",
                        language: dict["lang"] as? String ?? ""
                    )
                }
                return
            case "meta":
                if let t = dict["title"] as? String, !t.isEmpty {
                    model.mediaSessionTitle = t
                }
                return
            case "retract":
                if let s = dict["url"] as? String, let u = URL(string: s) {
                    model.retract(url: u)
                }
                return
            case "debug":
                // Always collected, shown only when the Diagnostics setting is
                // on — so turning it on reveals the log already captured rather
                // than requiring a reload.
                model.reportDebug(
                    url: dict["url"] as? String ?? "",
                    verdict: dict["verdict"] as? String ?? "",
                    host: dict["host"] as? String ?? "",
                    source: dict["src"] as? String ?? ""
                )
                return
            default:
                break // "video"
            }

            guard let urlString = dict["url"] as? String,
                  let url = URL(string: urlString) else { return }
            let title = dict["title"] as? String ?? ""

            // Replay the exact context the page used, or the CDN rejects us.
            // The JS already applied the rule's referer mode (origin vs full URL).
            var headers: [String: String] = [:]
            if let referer = dict["referer"] as? String, !referer.isEmpty {
                headers["Referer"] = referer
            }
            let ua = dict["ua"] as? String
            if let ua, !ua.isEmpty { lastUserAgent = ua }

            // A rule may narrow which extra headers to send; with no rule we
            // send everything we captured, as before.
            let allowed = dict["headers"] as? [String]
            func wants(_ name: String) -> Bool { allowed?.contains(name) ?? true }

            if wants("origin"),
               let origin = dict["origin"] as? String, !origin.isEmpty, origin != "null" {
                headers["Origin"] = origin
            }
            if wants("user-agent"), let ua, !ua.isEmpty {
                headers["User-Agent"] = ua
            }
            if wants("cookie"),
               let cookie = dict["cookie"] as? String, !cookie.isEmpty {
                headers["Cookie"] = cookie
            }

            let type = (dict["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            model.report(url: url, title: title, headers: headers, contentType: type)
        }
    }
}

/// Mirrors Android `isBrowserVideoUrl` / the JS `isPlayable` in ExtractionScript.
/// Extension alone is not enough — plenty of manifests are extensionless
/// (`/hls/<token>/<token>`) or masquerade as `.txt`.
enum VideoURL {
    private static let rejectedSuffixes = [
        ".ts", ".m4s", ".js", ".mjs", ".css", ".json",
        ".gif", ".png", ".jpg", ".jpeg", ".ico", ".svg", ".webp", ".xml",
    ]
    private static let acceptedSuffixes = [".m3u8", ".mpd", ".mp4", ".webm", ".mkv"]

    static func looksLikeVideo(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        // blob:/data: are in-page handles no external player can resolve.
        guard !s.hasPrefix("blob:"), !s.hasPrefix("data:") else { return false }
        let path = s.components(separatedBy: "?").first ?? s

        // DASH byte-range segments aren't standalone playable.
        if s.contains("bytestart="), s.contains("byteend=") { return false }
        if rejectedSuffixes.contains(where: path.hasSuffix) { return false }
        if acceptedSuffixes.contains(where: path.hasSuffix) { return true }

        // Extensionless HLS endpoints.
        if path.contains("/hls/") { return true }
        // Playlists served as .txt.
        if path.hasSuffix(".txt"),
           ["master", "index", "/v4/", "/hls", "playlist"].contains(where: path.contains) {
            return true
        }
        // Extension hidden in a query param.
        return s.contains(".m3u8") || s.contains(".mpd")
    }
}
