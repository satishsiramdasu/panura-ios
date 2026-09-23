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

    /// Where the browser lands with nothing loaded. A blank web view reads as a
    /// broken tab rather than an empty one, so there is deliberately no
    /// about:blank state — same call as Android's BROWSER_START_URL.
    static let startPage = URL(string: "https://www.google.com/")!

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    /// Every script and setting the sniffer depends on. Shared so the offscreen
    /// embed extractor is configured identically to the visible browser — a
    /// difference between the two would show up as "detects inline but not in an
    /// embed", which is exactly the bug class that is hardest to find.
    static func makeConfiguration(
        handler: WKScriptMessageHandler,
        privateMode: Bool = false
    ) -> WKWebViewConfiguration {
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

        // Sites that fetch the stream only on a play click. Registered last, so
        // every hook it exists to feed is already installed when it fires. It is
        // the one injection that touches the page rather than observing it, so
        // it is also the first thing to turn off if a page misbehaves on load.
        if UserDefaults.standard.object(forKey: "auto_play_click") as? Bool ?? true {
            contentController.addUserScript(WKUserScript(
                source: AutoPlayClickScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        // Page videos start in the page instead of jumping to Apple's
        // full-screen player on play; full screen stays a separate tap. Order among the
        // document-start scripts does not matter: this one only has to be in
        // place before the page's first play().
        let keepInline = UserDefaults.standard.object(forKey: "block_page_fullscreen") as? Bool ?? true
        if keepInline {
            contentController.addUserScript(WKUserScript(
                source: InlineVideoScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        // Text selection's Copy / Look Up menu on a long press, always. The
        // link and image menu is `allowsLinkPreview` instead — see makeUIView.
        //
        // Not a setting any more. Holding a page in this app means "give me
        // this video", and the system menu that answers with Copy Link and
        // Look Up is competing with that gesture — so the only sensible value
        // was the one it always had.
        contentController.addUserScript(WKUserScript(
            source: LongPressScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // The page's own poster, for the found-video sheet and the cast
        // screen. Document end: it reads meta tags and JSON-LD, which is a head
        // that has finished parsing.
        contentController.addUserScript(WKUserScript(
            source: PagePosterScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        // Tidies up after the page: font-measuring nodes a site meant to take
        // away and left behind. Document end, main frame only — it reads the
        // body's own children, and there is nothing to read before there is a
        // body.
        contentController.addUserScript(WKUserScript(
            source: FontProbeScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // Private browsing: a data store that is thrown away with the web view,
        // so cookies, cache and local storage never reach disk. It cannot be
        // swapped on a live web view, which is why the browser rebuilds one.
        if privateMode { config.websiteDataStore = .nonPersistent() }
        // Make the default user agent end in a Safari token.
        //
        // WKWebView's own UA omits `Version/x Safari/x` - it says
        // "...AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" and stops.
        // Sites that sniff the browser rather than test for features do not
        // recognise it, and Google in particular answers an unknown UA with its
        // 1998 no-JavaScript page: plain links, bordered buttons, "Google
        // offered in:". That is what an iPad was getting on the start page.
        //
        // `applicationNameForUserAgent` is appended to the default UA, so this
        // adds the missing tail without hard-coding a device or an OS version -
        // the rest of the string stays whatever WebKit says it is. Desktop mode
        // still replaces the whole UA with `BrowserModel.desktopUA`.
        config.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"
        config.allowsInlineMediaPlayback = true
        // The HTML5 Fullscreen API, off by default in WKWebView.
        //
        // Mobile sites hand a bare <video> to the system player, which has its
        // own fullscreen and needs nothing from us. Desktop sites - YouTube's
        // desktop player above all - build their own controls and call
        // `requestFullscreen()` on a <div>, which silently did nothing. That is
        // why fullscreen worked on mobile YouTube and was dead in desktop mode.
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Block the pop-under/new-window ads these sites open on tap.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        return config
    }


    func makeUIView(context: Context) -> WKWebView {
        let config = Self.makeConfiguration(
            handler: context.coordinator, privateMode: BrowserSession.shared.privateMode
        )

        // Offscreen extraction of gated embeds, reporting into the same model.
        let coordinator = context.coordinator
        let privateMode = BrowserSession.shared.privateMode
        coordinator.embeds.makeConfiguration = {
            // Same store as the visible browser: an offscreen extraction that
            // wrote cookies to disk would be a hole straight through private mode.
            Self.makeConfiguration(handler: coordinator, privateMode: privateMode)
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // The long press on a link or image: this is what draws the preview and
        // the Copy Link / Open in New Tab sheet with it. The CSS half of the
        // job — text selection — is LongPressScript.
        //
        // Not done through `WKUIDelegate.contextMenuConfigurationForElement`,
        // which looks like the right hook and is a trap: implementing it at all
        // replaces WebKit's default menu, and there is no way to hand the
        // default back, so the *off* state could never restore what it removed.
        webView.allowsLinkPreview = false
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
        // The page that was open, not the start page.
        //
        // This view is rebuilt more often than it looks: the identity carries
        // private mode and two settings, and on iPad a Split View resize
        // changes the layout around it. Every one of those used to land on
        // google.com. Private mode is the exception and clears `currentURL`
        // itself before it flips, because carrying a page across that boundary
        // is the one thing the boundary exists to prevent.
        webView.load(URLRequest(url: BrowserSession.shared.lastURL ?? Self.startPage))

        // Ad/tracker rule lists, then one reload so they apply to the current
        // page. Site rules are NOT injected here — the manifest names no domains
        // and the salt must never enter a web view. Instead each frame posts
        // `ready` and we push back only that frame's own resolved rule (see the
        // message handler).
        // Off means no lists compiled and none applied — the setting is not a
        // filter over a running blocker, it decides whether one exists.
        if UserDefaults.standard.object(forKey: "ad_block") as? Bool ?? true {
            Task { @MainActor in
                let lists = await FilterListUpdater.current()
                for list in lists {
                    webView.configuration.userContentController.add(list)
                }
                webView.reload()
            }
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
                // Let a page's own fullscreen video turn the phone.
                //
                // The app is locked to portrait outside the player, and that
                // lock reaches a site's fullscreen video too - it is presented
                // inside this app, so it inherits the app's orientation mask
                // and was stuck upright with no way to turn it. A video filling
                // the screen is the one moment on a phone where landscape is
                // the point.
                //
                // `fullscreenState` covers the HTML Fullscreen API, which is
                // what a desktop-layout site uses for its own player. A mobile
                // site that hands a bare <video> to the system player is a
                // different path: WebKit presents that in a window of its own,
                // which declares its orientations independently of ours.
                webView.observe(\.fullscreenState, options: [.new]) { wv, _ in
                    Task { @MainActor in
                        switch wv.fullscreenState {
                        case .enteringFullscreen, .inFullscreen:
                            OrientationManager.allowAll()
                        default:
                            // Only if nothing else is holding it open - the
                            // app's own player sets a mask of its own and must
                            // not have it reset from under it.
                            if !PlaybackSession.shared.isPlayingSomething {
                                OrientationManager.reset()
                            }
                        }
                    }
                },
                // The only signal a single-page app gives. `history.pushState`
                // fires no navigation delegate callback at all — not
                // didStartProvisional, not didFinish — so without this a React
                // route change leaves the address bar on the old URL and keeps
                // the previous page's detections in the list.
                webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                    Task { @MainActor in self?.documentChanged(wv.url) }
                },
                // Scrolling down hides the app's bottom bar; scrolling up brings
                // it back, as on Android. Observed rather than taken from the
                // scroll view's delegate, which belongs to WKWebView — it
                // implements real behaviour through it, and replacing it costs
                // that.
                webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                    Task { @MainActor in self?.scrolled(sv) }
                },
            ]

        }

        @MainActor
        private func scrolled(_ scrollView: UIScrollView) {
            let y = scrollView.contentOffset.y
            // Rubber-banding at either end is not a scroll in that direction;
            // reading it as one hides the bar on a bounce.
            let bottom = scrollView.contentSize.height - scrollView.bounds.height
            guard y > 0, y < bottom else { return }
            BrowserSession.shared.scrolled(by: y - lastScrollY)
            lastScrollY = y
        }

        /// Last document we counted as "a page": host + path only.
        ///
        /// Query and fragment are deliberately excluded. Keying on them broke
        /// detection outright — a player that rewrites its own query after
        /// starting (`?t=`, `?autoplay=1`, a cache-buster) looked like a new
        /// route, so the stream was cleared from the list moments after it was
        /// found. A genuine SPA route change moves the path, which still resets.
        private var lastDocumentKey: String?

        /// The last route the page reported, so a router that announces the
        /// same URL twice does not clear a list twice.
        private var lastRouteKey: String?

        /// An in-page route change, reported by the injected script.
        ///
        /// Compared on the whole URL, query and fragment included - unlike
        /// `documentChanged`, which has to guess from the URL alone and so
        /// ignores both. Here there is nothing to guess: the page said it
        /// navigated.
        @MainActor
        private func routeChanged(to url: URL) {
            guard url.absoluteString != lastRouteKey else { return }
            lastRouteKey = url.absoluteString
            model.currentURL = url
            model.clearFindings()
            embeds.reset()
            lastScrollY = 0
            BrowserSession.shared.showBar()
        }

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
            // A new page starts at the top with the bar up: carrying the old
            // page's scroll offset over would read the jump back to zero as a
            // downward scroll and hide the bar on arrival.
            lastScrollY = 0
            BrowserSession.shared.showBar()
        }

        /// Where the page was when we last looked, so a scroll can be given a
        /// direction.
        private var lastScrollY: CGFloat = 0

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
            lastRouteKey = nil
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
            showErrorPage(in: webView, error: error)
        }

        /// Panura's own failure page, as on Android.
        ///
        /// WebKit's default is a bare white sheet reading "cannot open the
        /// page", with no way back and no retry — on a dark app, on a phone,
        /// that reads as a crash rather than a site that is down.
        ///
        /// Loaded with the failed URL as the base, which is what makes the
        /// page's Retry button work: `location.reload()` then re-requests the
        /// real address rather than the error page.
        private func showErrorPage(in webView: WKWebView, error: Error) {
            let ns = error as NSError
            guard ns.domain == NSURLErrorDomain else { return }
            // Cancelled is not a failure: it is what every interrupted load
            // reports — a second tap, a redirect, our own universal-link
            // re-issue — and painting an error over those would break ordinary
            // browsing.
            let ignored: Set<Int> = [
                NSURLErrorCancelled,
                NSURLErrorNetworkConnectionLost,   // retried by WebKit itself
            ]
            guard !ignored.contains(ns.code) else { return }

            let failed = (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
                ?? webView.url?.absoluteString ?? ""
            let (code, title, detail) = Self.describe(ns)
            let html = Self.errorPageHTML(code: code, title: title, detail: detail, url: failed)
            webView.loadHTMLString(html, baseURL: URL(string: failed))
        }

        /// The three lines the page shows. Deliberately plain — "no internet"
        /// and "this host does not exist" are different problems with different
        /// fixes, and one "couldn't load" covers up which one happened.
        private static func describe(_ error: NSError) -> (String, String, String) {
            switch error.code {
            case NSURLErrorNotConnectedToInternet:
                return ("Offline", "No internet connection",
                        "Check Wi-Fi or mobile data and try again.")
            case NSURLErrorTimedOut:
                return ("Timeout", "The site took too long",
                        "It may be busy or blocked. Try again in a moment.")
            case NSURLErrorCannotFindHost:
                return ("404", "Site not found",
                        "This address does not exist. Check the spelling.")
            case NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return ("Down", "Can't reach this site",
                        "The server isn't responding. It may be down.")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot:
                return ("Unsafe", "Connection isn't private",
                        "This site's security certificate could not be trusted.")
            default:
                return ("Error", "Couldn't open this page",
                        error.localizedDescription)
            }
        }

        /// Same page Android serves, down to the palette — the app looks the
        /// same on both phones when a site fails.
        private static func errorPageHTML(
            code: String, title: String, detail: String, url: String
        ) -> String {
            func escape(_ text: String) -> String {
                text.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
            }
            return """
            <!DOCTYPE html><html lang="en"><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
            <title>\(escape(title))</title>
            <style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{background:#0F0F0E;color:#fff;font-family:-apple-system,system-ui,sans-serif;
              display:flex;flex-direction:column;align-items:center;justify-content:center;
              min-height:100vh;padding:32px 24px;text-align:center;-webkit-tap-highlight-color:transparent}
            .code{font-size:64px;font-weight:800;color:#FFB300;line-height:1.1;letter-spacing:-2px}
            .ttl{font-size:18px;font-weight:600;margin-top:12px}
            .dsc{font-size:13px;color:rgba(255,255,255,0.6);margin-top:8px;line-height:1.5;max-width:280px}
            .url{font-size:11px;color:rgba(255,255,255,0.3);margin-top:16px;word-break:break-all;max-width:320px;line-height:1.4}
            .row{display:flex;gap:12px;margin-top:28px}
            button{padding:11px 24px;border-radius:50px;border:none;font-size:13px;font-weight:600;outline:none}
            .r{background:#FFB300;color:#3D2000}
            .b{background:#1E1E1D;color:#fff}
            </style></head><body>
            <div class="code">\(escape(code))</div>
            <div class="ttl">\(escape(title))</div>
            <div class="dsc">\(escape(detail))</div>
            <div class="url">\(escape(url))</div>
            <div class="row">
              <button class="b" onclick="window.history.back()">Back</button>
              <button class="r" onclick="window.location.reload()">Retry</button>
            </div>
            </body></html>
            """
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
                // Caught on the wire rather than in the page: this is a
                // navigation the app intercepted.
                model.report(
                    url: url, title: pageTitle, headers: headers, source: .network
                )
                return .cancel
            }

            // Universal links. Tapping a youtube.com result in Google hands the
            // page to the YouTube app: WebKit resolves universal links itself,
            // before the URL is ever loaded, and it does that for exactly one
            // kind of navigation — a user's tap on a link that leaves the
            // current site. Allowing it here is what throws the user out of the
            // browser mid-session.
            //
            // So the tap is cancelled and the same URL loaded programmatically.
            // A load the app starts is never handed to another app, which is
            // also why the pop-under path above (`createWebViewWith`) is safe.
            // Everything else about the navigation survives: it enters the back
            // list normally, and the Referer WebKit would have sent is set by
            // hand, since a programmatic load carries none.
            if navigationAction.navigationType == .linkActivated,
               navigationAction.targetFrame?.isMainFrame == true,
               let url = navigationAction.request.url,
               navigationAction.request.httpMethod.map({ $0 == "GET" }) ?? true,
               // A same-page anchor is not a navigation to re-issue — reloading
               // the page to reach #section would lose the page's state.
               !Self.isSamePageAnchor(url, from: webView.url) {
                var request = URLRequest(url: url)
                if let page = webView.url {
                    request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
                }
                webView.load(request)
                return .cancel
            }
            return .allow
        }

        /// True when the two URLs differ only by fragment.
        private static func isSamePageAnchor(_ url: URL, from current: URL?) -> Bool {
            guard let current, url.fragment != nil else { return false }
            var a = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var b = URLComponents(url: current, resolvingAgainstBaseURL: false)
            a?.fragment = nil
            b?.fragment = nil
            return a?.url == b?.url
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
            case "route":
                // A single-page app moved between routes. Only pushState,
                // popstate and hashchange reach here - see ExtractionScript for
                // why replaceState deliberately does not.
                //
                // The main frame only. The sniffer runs in every frame and so
                // this arrives from every frame, and an ad iframe pushing state
                // is not the page moving: taken at face value it threw away the
                // page's findings and poster, and pointed `currentURL` — which
                // is the address bar, and the key every per-site setting is
                // looked up by — at the advertiser.
                guard message.frameInfo.isMainFrame else { return }
                if let s = dict["url"] as? String, let u = URL(string: s) {
                    routeChanged(to: u)
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
                // Artwork the site set for the item that is playing. Better than
                // anything the page says about itself, and it has been arriving
                // unread since the sniffer was written.
                if let a = dict["artwork"] as? String, let u = URL(string: a) {
                    model.sessionArtwork = u
                }
                return
            case "poster":
                if let s = dict["url"] as? String, let u = URL(string: s) {
                    model.pagePoster = u
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
                // The sniffer still announces what it decided; nothing listens
                // any more. Kept as a case so an announcement is swallowed
                // rather than falling through to the video handler.
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
            // A rule claimed this URL. The probe needs to know: those hosts hand
            // out single-use tokens, and a probe that spends one leaves the
            // player with a 410.
            let ruleMatched = !((dict["siteId"] as? String) ?? "").isEmpty
            model.report(
                url: url, title: title, headers: headers,
                castHeaders: full, contentType: type, ruleMatched: ruleMatched,
                source: DetectionSource(raw: dict["source"] as? String)
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
        // imgproxy/thumbor-style derivatives — .../original.mp4/rs:fit:480:270/vts:360.
        // The server renders a poster strip from those, never the video.
        if let ext = [".mp4/", ".webm/", ".mkv/", ".m3u8/", ".mpd/"]
            .compactMap({ path.range(of: $0) }).first,
           path[ext.lowerBound...].contains(":") { return false }
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
