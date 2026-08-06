import AVFoundation
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

    /// Keep the page's own media running once the app leaves the foreground —
    /// the standard browser behaviour (Safari, Brave). Two halves: native PiP,
    /// enabled on the config, and a `.playback` audio session, claimed here.
    ///
    /// Off by default and only claimed on demand, because holding a `.playback`
    /// session interrupts whatever else the phone is playing.
    @Published var backgroundPlayback = UserDefaults.standard.bool(forKey: BrowserModel.backgroundKey) {
        didSet {
            UserDefaults.standard.set(backgroundPlayback, forKey: Self.backgroundKey)
            applyAudioSession()
        }
    }

    private static let backgroundKey = "browser_background_play"

    /// Without a `.playback` session iOS suspends web media the moment the app
    /// resigns active, whatever the page itself does. Paired with the `audio`
    /// entry in UIBackgroundModes, which the VLC player already required.
    ///
    /// This only decides whether *we* keep the pipeline alive. A page whose
    /// player pauses itself on `visibilitychange` still pauses; that is the
    /// site's own behaviour and nothing here overrides it.
    func applyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if backgroundPlayback {
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        } else {
            // `.ambient` stops on lock and mixes rather than interrupting.
            // VLCPlayerModel re-claims `.playback` when it starts a stream.
            try? session.setCategory(.ambient)
        }
    }

    /// Put the playing video into PiP, which is the only thing that actually
    /// survives backgrounding — a `.playback` session alone keeps <audio>
    /// alive, but iOS suspends inline <video> the moment the app deactivates.
    ///
    /// Called straight off the toggle because `webkitSetPresentationMode`
    /// wants a user gesture, and the tap is one. Deferring it to
    /// `willResignActive` looks tidier and fails the gesture check.
    ///
    /// Main frame only: cross-origin iframes are unreachable from here, so an
    /// embedded player still needs its own PiP button. `completion` reports
    /// whether a video was actually found and switched.
    func enterPictureInPicture(completion: @escaping (Bool) -> Void) {
        let js = """
        (function () {
          var v = document.querySelector('video');
          if (!v || v.paused) return false;
          if (typeof v.webkitSetPresentationMode !== 'function') return false;
          if (!v.webkitSupportsPresentationMode ||
              !v.webkitSupportsPresentationMode('picture-in-picture')) return false;
          v.webkitSetPresentationMode('picture-in-picture');
          return true;
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            completion((result as? Bool) ?? (result as? NSNumber)?.boolValue ?? false)
        }
    }

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
        // `#referer=` names the Referer this URL must be fetched with; strip it
        // and send the header. WebKit applies it to this request only — a later
        // in-page navigation carries the page's own referer, same as Android.
        webView?.load(RefererFragment.request(for: url))
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

    func report(
        url: URL,
        title: String,
        headers: [String: String],
        castHeaders: [String: String] = [:],
        contentType: String? = nil
    ) {
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        let name = title.isEmpty ? mediaSessionTitle : title
        foundVideos.append(
            ExtractedVideo(
                url: url, title: name, headers: headers,
                castHeaders: castHeaders.isEmpty ? headers : castHeaders,
                contentType: contentType
            )
        )
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
