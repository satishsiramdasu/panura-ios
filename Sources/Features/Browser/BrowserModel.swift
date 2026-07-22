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
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { clearFindings(); webView?.reload() }
    func stop() { webView?.stopLoading() }

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
    }

    // MARK: detection

    func report(url: URL, title: String, headers: [String: String]) {
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        let name = title.isEmpty ? mediaSessionTitle : title
        foundVideos.append(ExtractedVideo(url: url, title: name, headers: headers))
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
            subtitles: foundSubtitles
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
