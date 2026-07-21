import SwiftUI
import WebKit

@MainActor
final class BrowserModel: ObservableObject {
    @Published var isLoading = false
    @Published var currentURL: URL?
    @Published var foundVideos: [ExtractedVideo] = []

    private weak var webView: WKWebView?
    private var seen = Set<String>()

    func attach(_ webView: WKWebView) { self.webView = webView }

    func load(_ text: String) {
        let url = Self.normalize(text)
        foundVideos.removeAll()
        seen.removeAll()
        webView?.load(URLRequest(url: url))
    }

    func report(url: URL, title: String, headers: [String: String]) {
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        foundVideos.append(ExtractedVideo(url: url, title: title, headers: headers))
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
