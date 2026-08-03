import WebKit

/// Loads a gated embed offscreen so its stream can be detected.
///
/// Port of Android's headless `WebViewExtractor`, and the third attempt at the
/// `#referer=` problem. The first two tried to keep the embed inside the page —
/// pointing the iframe at a local http relay, then at a custom scheme. Both
/// failed identically: the host page is https, neither `http://127.0.0.1` nor
/// `panura-frame:` is a trustworthy origin to WebKit, so the frame was mixed
/// content and blocked before any request left the page. There is no public API
/// to mark a custom scheme secure, so no page-side rewrite can work.
///
/// A **main-frame** load has neither problem: `URLRequest` may carry a `Referer`
/// header, and mixed content does not apply to a top-level document. So the
/// embed is loaded in its own offscreen web view, with the same sniffer scripts
/// and the same message handler as the visible browser. Hits land in the same
/// `BrowserModel`, so the found bar behaves exactly as it does for an inline
/// detection.
///
/// The visible iframe stays blank — nothing can fix that without the site's
/// cooperation. What the user gets is the stream, which is the point.
@MainActor
final class EmbedExtractor: NSObject {
    /// Builds a configuration carrying the sniffer scripts and the `panura`
    /// handler. Supplied by `WebViewContainer` so both web views stay identical.
    var makeConfiguration: (() -> WKWebViewConfiguration)?
    var log: ((_ url: String, _ verdict: String) -> Void)?

    /// Android gives extraction 20s; a little more here since we never retry.
    private let timeout: Duration = .seconds(25)

    private var active: [String: WKWebView] = [:]
    /// Attempted URLs — an embed is extracted once per page, however many times
    /// the observer sees the iframe.
    private var attempted = Set<String>()

    /// Loads `url` offscreen with `referer`. `host` only provides a place in the
    /// view hierarchy: a web view outside a window gets its timers throttled,
    /// and the extraction would never finish.
    func extract(url: URL, referer: String, host: UIView) {
        let key = url.absoluteString
        guard !attempted.contains(key), let makeConfiguration else { return }
        attempted.insert(key)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                configuration: makeConfiguration())
        // Present enough to run, invisible enough not to matter.
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        host.addSubview(webView)
        host.sendSubviewToBack(webView)
        active[key] = webView

        var request = URLRequest(url: url)
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        webView.load(request)
        log?(key, "embed: loading offscreen with referer \(referer.isEmpty ? "(none)" : referer)")

        Task { [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(25))
            self?.finish(key)
        }
    }

    /// Tears the extraction web view down. Detections already reported stay in
    /// the model — this only stops the page from running on.
    private func finish(_ key: String) {
        guard let webView = active.removeValue(forKey: key) else { return }
        webView.stopLoading()
        webView.removeFromSuperview()
        log?(key, "embed: extraction window closed")
    }

    /// New page in the visible browser — forget what we tried on the old one.
    func reset() {
        for key in active.keys { finish(key) }
        attempted.removeAll()
    }
}
