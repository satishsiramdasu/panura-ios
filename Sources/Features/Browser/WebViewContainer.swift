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

        let script = WKUserScript(
            source: ExtractionScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        contentController.addUserScript(script)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Block the pop-under/new-window ads these sites open on tap.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.attach(webView)
        webView.load(URLRequest(url: URL(string: "https://www.google.com")!))

        // Compile + attach the ad/tracker blocklist, then (re)load.
        Task { @MainActor in
            if let list = await ContentBlocker.load() {
                webView.configuration.userContentController.add(list)
                webView.reload()
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }

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
        }

        func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
            model.isLoading = false
            model.currentURL = webView.url
        }

        // Catch direct video navigations the JS scan would miss.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url,
               VideoURL.looksLikeVideo(url) {
                model.report(url: url, title: webView.title ?? "", headers: [:])
                return .cancel
            }
            return .allow
        }

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
            model.report(url: url, title: title, headers: [:])
        }
    }
}

enum VideoURL {
    static func looksLikeVideo(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return s.contains(".m3u8") || s.contains(".mp4") || s.contains(".mpd")
    }
}
