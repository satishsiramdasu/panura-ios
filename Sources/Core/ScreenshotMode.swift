#if DEBUG
import Foundation

/// Fills the app with enough state to photograph, for the App Store screenshot
/// run in `Tests/Screenshots/StoreScreenshots.swift`.
///
/// DEBUG only, and gated on a launch argument the test passes — the screenshot
/// build is a Debug one, and nothing here can exist in a release binary. Every
/// release path (`ios-release.yml`) archives Release, so this file is not
/// compiled into anything that reaches App Store Connect.
///
/// **Why seed at all.** The screenshots that sell this app are the ones showing
/// a stream detected on a real page — and driving that off the live web on a CI
/// runner means a third-party site, its ads and its consent dialog deciding
/// whether the run produces a usable image. The UI in these shots is the real
/// UI, rendering real models; only the page and the streams behind the bar are
/// fixtures.
enum ScreenshotMode {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-panura-screenshots")
    }

    /// The page the browser shot is taken on: our own, so no other company's
    /// branding ends up in a screenshot on the App Store.
    static let page = "https://panura.app"

    /// Written before `BrowsingStore.shared` is first touched — it loads its
    /// lists in `init`, so anything set afterwards would not be read until the
    /// next launch.
    static func seedDefaults() {
        guard isActive else { return }
        let defaults = UserDefaults.standard

        // A fresh simulator has no history, and Home without its grids is a
        // screenshot of an empty screen. These are ordinary, legitimate video
        // sites — nothing that reads as a piracy directory in a store listing.
        let visits: [HostVisit] = [
            HostVisit(host: "archive.org", label: "Internet Archive", visits: 14, lastVisit: ago(hours: 2)),
            HostVisit(host: "vimeo.com", label: "Vimeo", visits: 9, lastVisit: ago(hours: 6)),
            HostVisit(host: "wikipedia.org", label: "Wikipedia", visits: 7, lastVisit: ago(hours: 20)),
            HostVisit(host: "panura.app", label: "Panura", visits: 5, lastVisit: ago(hours: 26)),
        ]
        let shortcuts: [SiteEntry] = [
            SiteEntry(url: "https://archive.org/details/movies", title: "Internet Archive"),
            SiteEntry(url: "https://vimeo.com/watch", title: "Vimeo"),
            SiteEntry(url: "https://panura.app", title: "Panura"),
        ]
        // Deliberately unfinished and unbranded: this is the user's own
        // watch-in-progress, so the titles are the kind of thing a file is
        // actually called.
        let resumes: [ResumeEntry] = [
            ResumeEntry(
                url: "https://archive.org/download/demo/coastline-drive.mp4",
                title: "Coastline drive",
                position: 1_284, duration: 3_120, updated: ago(hours: 3)
            ),
            ResumeEntry(
                url: "file:///var/mobile/Media/rooftop-timelapse.mkv",
                title: "Rooftop timelapse",
                position: 96, duration: 540, isLocal: true, updated: ago(hours: 30)
            ),
        ]

        write(visits, "home_host_visits")
        write(shortcuts, "home_shortcuts")
        write(resumes, "home_resume")
        // Recents is per-page where the tally above is per-host; both grids are
        // on Home, and one of them being empty is as obvious as both.
        write(shortcuts, "home_history")
    }

    /// The streams the found-bar reports on the browser shot.
    ///
    /// Two of them, of different qualities, because one is the case the bar was
    /// redesigned away from: the badge counts and the quality rows are what the
    /// screenshot is for.
    static func demoVideos() -> [ExtractedVideo] {
        let base = "https://cdn.panura.app/demo"
        return [
            ExtractedVideo(
                url: URL(string: "\(base)/1080p/index.m3u8")!,
                title: "Coastline drive",
                headers: [:],
                contentType: "hls",
                source: .network
            ),
            ExtractedVideo(
                url: URL(string: "\(base)/720p/index.m3u8")!,
                title: "Coastline drive",
                headers: [:],
                contentType: "hls",
                source: .network
            ),
        ]
    }

    /// Loads the demo page and keeps the found-bar populated while the shot is
    /// taken.
    ///
    /// Re-applied on a timer rather than set once: `BrowserModel` clears
    /// `foundVideos` on every navigation, and a fixture set before the page
    /// commits would be wiped by the load it is meant to accompany. Ten seconds
    /// covers a cold web view on a CI runner and then stops.
    @MainActor
    static func prime(_ model: BrowserModel) {
        guard isActive else { return }

        let videos = demoVideos()
        let started = Date()
        // Both halves are retried, for the same reason: this runs from
        // BrowserView's `onAppear`, and `BrowserModel.load` is
        // `webView?.load(…)` — optional. At launch the web view may not exist
        // yet, and that load then silently does nothing, which is exactly how
        // the browser screenshot came out blank. Detections need the retry too,
        // because every navigation clears them.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            Task { @MainActor in
                if Date().timeIntervalSince(started) > 20 {
                    timer.invalidate()
                    return
                }
                // `isLoading` keeps the retry from restarting a load already in
                // flight: `currentURL` is only set once the page commits, so
                // without it a slow page would be cancelled and re-requested
                // every second and never arrive.
                if model.currentURL == nil, !model.isLoading { model.load(page) }
                if model.foundVideos.isEmpty { model.foundVideos = videos }
            }
        }
    }

    private static func ago(hours: Int) -> Date {
        Date().addingTimeInterval(-Double(hours) * 3_600)
    }

    private static func write<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
#endif
