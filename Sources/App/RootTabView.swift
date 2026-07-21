import SwiftUI

/// Mirrors the Android `HomeScreen` tab layout:
/// Home · Browser · Downloads · Stream · Videos · Settings.
struct RootTabView: View {
    @State private var selection: Tab = .home

    enum Tab: Hashable { case home, browser, downloads, stream, videos, settings }

    var body: some View {
        TabView(selection: $selection) {
            HomeView(onOpenBrowser: { selection = .browser })
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            BrowserView()
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
