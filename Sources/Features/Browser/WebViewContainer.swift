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

    /// Every script and setting the sniffer depends on. Shared so the offscreen
    /// embed extractor is configured identically to the visible browser — a
    /// difference between the two would show up as "detects inline but not in an
    /// embed", which is exactly the bug class that is hardest to find.
    static func makeConfiguration(handler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let contentController = WKUserContentController()
        contentController.add(handler, name: "panura")

        // Identity marker + PanuraExtractor bridge first, so a page script that
        // checks for either finds it however early it runs.
        contentController.addUserScript(WKUserScript(
            source: PanuraBridgeScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        // Reports `#referer=` iframes so they can be extracted offscreen.
        contentController.addUserScript(WKUserScript(
            source: FrameRelayScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        // Ad/pop neutralization next, at document start, so it beats inline
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
        return config
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = Self.makeConfiguration(handler: context.coordinator)

        // Offscreen extraction of gated embeds, reporting into the same model.
        let coordinator = context.coordinator
        coordinator.embeds.makeConfiguration = { Self.makeConfiguration(handler: coordinator) }
        coordinator.embeds.log = { [weak model] url, verdict in
            Task { @MainActor in
                model?.reportDebug(url: url, verdict: verdict, host: "embed", source: "frame-relay")
            }
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
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

        // Ad/tracker rule lists, then one reload so they apply to the current
        // page. Site rules are NOT injected here — the manifest names no domains
        // and the salt must never enter a web view. Instead each frame posts
        // `ready` and we push back only that frame's own resolved rule (see the
        // message handler).
        Task { @MainActor in
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
        /// Offscreen extraction of `#referer=` embeds; held here so it lives as
        /// long as the view.
        let embeds = EmbedExtractor()
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
                // The only signal a single-page app gives. `history.pushState`
                // fires no navigation delegate callback at all — not
                // didStartProvisional, not didFinish — so without this a React
                // route change leaves the address bar on the old URL and keeps
                // the previous page's detections in the list.
                webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.documentChanged(wv.url) }
                },
            ]
        }

        /// Last document we counted as "a page": host + path only.
        ///
        /// Query and fragment are deliberately excluded. Keying on them broke
        /// detection outright — a player that rewrites its own query after
        /// starting (`?t=`, `?autoplay=1`, a cache-buster) looked like a new
        /// route, so the stream was cleared from the list moments after it was
        /// found. A genuine SPA route change moves the path, which still resets.
        private var lastDocumentKey: String?

        @MainActor
        private func documentChanged(_ url: URL?) {
            guard let url else { return }
            model.currentURL = url

            let key = "\(url.host ?? "")\(url.path)"
            guard key != lastDocumentKey else { return }
            let isFirst = lastDocumentKey == nil
            lastDocumentKey = key
            // Nothing to reset on the first observation, and clearing here would
            // race a detection from a page that redirected on load.
            guard !isFirst else { return }

            model.clearFindings()
            embeds.reset()
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
            // Safe to reset unconditionally: extraction web views are created
            // without a navigation delegate, so this only ever fires for the
            // visible browser.
            embeds.reset()
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
            // A scheme we don't render is an app handoff — youtube://, intent://,
            // itms-apps:// and friends. WKWebView passes those to the system,
            // which is how a page throws the user out of the browser mid-session
            // (YouTube does it on sign-in). A tab should stay a tab, so they are
            // dropped. Nothing here opens them; the browser simply ignores them.
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               !Self.webSchemes.contains(scheme) {
                return .cancel
            }

            if let rawURL = navigationAction.request.url,
               VideoURL.looksLikeVideo(rawURL) {
                // Same context capture as the JS path: the page we're leaving
                // is the Referer the CDN expects.
                let (url, fragmentReferer) = RefererFragment.split(rawURL)
                var headers: [String: String] = [:]
                if let page = webView.url {
                    headers["Referer"] = page.absoluteString
                    if let scheme = page.scheme, let host = page.host {
                        headers["Origin"] = "\(scheme)://\(host)"
                    }
                }
                if let ua = lastUserAgent { headers["User-Agent"] = ua }
                // Explicit instruction beats the inferred page URL.
                if let fragmentReferer { headers["Referer"] = fragmentReferer }
                // Same rule as the JS path: the browser's page title, not
                // whichever frame or extraction view happened to catch this.
                let pageTitle = model.pageTitle.isEmpty ? (webView.title ?? "") : model.pageTitle
                model.report(url: url, title: pageTitle, headers: headers)
                return .cancel
            }
            return .allow
        }

        /// Schemes the web view actually renders. Everything else is a handoff
        /// to some other app, which a browser tab has no business performing.
        private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob"]

        /// UA captured from the page, reused for hits found via navigation.
        private var lastUserAgent: String?

        /// `window.__panuraRule = {…}` for the frame — the manifest entry minus
        /// its `id` hashes (the page has no use for them and shouldn't see them).
        static func ruleInjectionJS(_ rule: [String: Any]) -> String? {
            var r = rule
            r.removeValue(forKey: "id")
            guard let data = try? JSONSerialization.data(withJSONObject: r),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return "window.__panuraRule = \(json);"
        }

        // Hits posted from the injected extraction script.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "panura",
                  let dict = message.body as? [String: Any] else { return }

            switch dict["kind"] as? String {
            case "ready":
                // A frame's sniffer is up. Resolve its rule by the FRAME's own
                // host (authoritative, from WebKit — not anything the page said)
                // and push only that one rule back into that one frame. No list,
                // no salt, no other site's domains ever reach the page.
                let host = message.frameInfo.securityOrigin.host
                guard !host.isEmpty else { return }
                let frame = message.frameInfo
                let wv = message.webView
                Task { @MainActor in
                    guard let rule = await ManifestStore.rule(forHost: host),
                          let js = Self.ruleInjectionJS(rule) else { return }
                    // Same content world the sniffer runs in (the default page
                    // world), and only into this one frame.
                    wv?.evaluateJavaScript(js, in: frame, in: .page, completionHandler: nil)
                }
                return
            case "embed":
                // A `#referer=` iframe the page cannot load itself. Extract it
                // offscreen as a main-frame load, where a Referer header is legal.
                guard let s = dict["url"] as? String, let u = URL(string: s),
                      let host = message.webView else { return }
                embeds.extract(url: u, referer: dict["referer"] as? String ?? "", host: host)
                return
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
            case "confirm":
                if let s = dict["url"] as? String, let u = URL(string: s) {
                    model.confirmType(url: u, type: dict["type"] as? String ?? "hls")
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
                  let rawURL = URL(string: urlString) else { return }
            // Every JS hook funnels through here, so stripping `#referer=` once
            // covers xhr/fetch/src/DOM-scan and the PanuraExtractor bridge.
            let (url, fragmentReferer) = RefererFragment.split(rawURL)
            // Main-frame title, matching Android's `view.title`. The JS reports
            // its own frame's document.title, which on an embed is the player
            // iframe's — "Player", the CDN's name, or empty — never the title
            // of the page the user is actually watching.
            //
            // `model.pageTitle` is the right source even for offscreen embed
            // extraction: that web view loads the embed as its own main frame,
            // so its `.title` is the embed's, while the model still holds the
            // browser's page.
            let reported = dict["title"] as? String ?? ""
            let title = model.pageTitle.isEmpty ? reported : model.pageTitle

            // Replay the exact context the page used, or the CDN rejects us.
            // The JS already applied the rule's referer mode (origin vs full URL).
            //
            // An extraction web view needs no special case: it loads the embed as
            // its main frame, so `location.*` there IS the embed — which is what
            // the CDN expects to see on the stream request.
            //
            // Referer priority, mirroring Android's `onEmbedDetected`:
            //  1. `#referer=` fragment — the CDN's explicit instruction
            //  2. what the JS captured (rule's referer mode, applied in-page)
            //  3. nothing; the player falls back to no Referer
            var headers: [String: String] = [:]
            if let referer = dict["referer"] as? String, !referer.isEmpty {
                headers["Referer"] = referer
            }
            if let fragmentReferer { headers["Referer"] = fragmentReferer }
            let ua = dict["ua"] as? String
            if let ua, !ua.isEmpty { lastUserAgent = ua }

            // A rule may narrow which extra headers to send; with no rule we
            // send everything we captured, as before.
            let allowed = dict["headers"] as? [String]
            func wants(_ name: String) -> Bool { allowed?.contains(name) ?? true }

            // What a TV should send: Referer and User-Agent, and deliberately
            // NOT Origin or Cookie.
            //
            // Established by casting one video from both phones to the same TV.
            // Android sent [User-Agent, Referer, sec-ch-ua*, Accept] and played;
            // iOS sent [Origin, Cookie, Referer, User-Agent] and the CDN answered
            // HTTP 200 with a body reading "security error". Same URL, same TV,
            // same second.
            //
            // Cookies are the trap. A page's session cookie — cf_clearance above
            // all — is bound to the IP and User-Agent that obtained it, so
            // replaying it from a second device is not neutral: it is a cookie
            // the origin can see is wrong, and it is rejected harder than sending
            // none. Origin likewise marks the request as cross-site to a CDN that
            // is happy to serve a plain one.
            //
            // A site that genuinely needs a cookie loses nothing: the TV reports
            // the failure and the proxy takes over within about 12ms, and the
            // proxy fetches from this device, where the cookie is valid.
            var full = headers
            if let ua, !ua.isEmpty { full["User-Agent"] = ua }
            // Accept is not optional to these CDNs, and its absence is what
            // actually broke direct casting. One site serves the playlist to a
            // request carrying nothing but `Accept: */*`, and answers "security
            // error" to a request with a perfect Referer, User-Agent and cookies
            // and no Accept. ExoPlayer sends none of its own; Android only worked
            // because it forwards the browser's.
            full["Accept"] = "*/*"

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
            model.report(
                url: url, title: title, headers: headers,
                castHeaders: full, contentType: type
            )
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
