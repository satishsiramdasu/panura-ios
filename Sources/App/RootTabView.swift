import SwiftUI

/// Mirrors the Android `HomeScreen` tab layout, minus Downloads:
/// Home · Browser · Stream · Videos · Settings.
///
/// iOS ships no download feature at all. Saving streamed content is the clearest
/// App Review 5.2.3 problem in this app, and a flag-gated feature still ships the
/// code — so it is removed rather than disabled.
struct RootTabView: View {
    @State private var selection: Tab = .home
    /// Address typed on Home, waiting for the Browser tab to pick it up. The
    /// browser owns its WebView across tab switches, so the hand-off has to be
    /// state here rather than a fresh `BrowserView(url:)`.
    @State private var pendingAddress: String?

    enum Tab: Hashable { case home, browser, stream, videos, settings }

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
