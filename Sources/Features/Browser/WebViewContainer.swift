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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.attach(webView)
        webView.load(URLRequest(url: URL(string: "https://www.google.com")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }

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
