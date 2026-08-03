import SwiftUI

/// Mirrors the Android `HomeScreen` tab layout:
/// Home · Browser · Downloads · Stream · Videos · Settings.
struct RootTabView: View {
    @State private var selection: Tab = .home
    /// Address typed on Home, waiting for the Browser tab to pick it up. The
    /// browser owns its WebView across tab switches, so the hand-off has to be
    /// state here rather than a fresh `BrowserView(url:)`.
    @State private var pendingAddress: String?

    enum Tab: Hashable { case home, browser, downloads, stream, videos, settings }

    var body: some View {
        TabView(selection: $selection) {
            HomeView(onOpenBrowser: { address in
                pendingAddress = address
                selection = .browser
            })
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            BrowserView(pendingAddress: $pendingAddress)
                .tabItem { Label("Browser", systemImage: "globe") }
                .tag(Tab.browser)

            if FeatureFlags.downloadsEnabled {
                DownloadsView()
                    .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                    .tag(Tab.downloads)
            }

            StreamView()
                .tabItem { Label("Stream", systemImage: "link") }
                .tag(Tab.stream)

            LocalVideosView()
                .tabItem { Label("Videos", systemImage: "film.fill") }
                .tag(Tab.videos)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(PanuraTheme.accent)
    }
}
