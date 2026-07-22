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
        // Video sniffer at document end.
        contentController.addUserScript(WKUserScript(
            source: ExtractionScript.source,
            injectionTime: .atDocumentEnd,
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

        // Compile + attach the ad/tracker rule lists (static base + oisd, plus
        // the converted EasyList/uBlock lists), then (re)load so they apply.
        Task { @MainActor in
            let lists = await FilterListUpdater.current()
            for list in lists {
                webView.configuration.userContentController.add(list)
            }
            if !lists.isEmpty { webView.reload() }
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
                  let dict = message.body as? [String: Any],
                  let urlString = dict["url"] as? String,
                  let url = URL(string: urlString) else { return }
            let title = dict["title"] as? String ?? ""

            // Replay the exact context the page used, or the CDN rejects us.
            var headers: [String: String] = [:]
            if let referer = dict["referer"] as? String, !referer.isEmpty {
                headers["Referer"] = referer
            }
            if let origin = dict["origin"] as? String, !origin.isEmpty, origin != "null" {
                headers["Origin"] = origin
            }
            if let ua = dict["ua"] as? String, !ua.isEmpty {
                headers["User-Agent"] = ua
                lastUserAgent = ua
            }
            if let cookie = dict["cookie"] as? String, !cookie.isEmpty {
                headers["Cookie"] = cookie
            }
            model.report(url: url, title: title, headers: headers)
        }
    }
}

enum VideoURL {
    static func looksLikeVideo(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return s.contains(".m3u8") || s.contains(".mp4") || s.contains(".mpd")
    }
}
