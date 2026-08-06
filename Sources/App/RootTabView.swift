import SwiftUI

/// Mirrors the Android `HomeScreen` tab layout, minus Downloads:
/// Home · Browser · Stream · Videos · Settings.
///
/// iOS ships no download feature at all. Saving streamed content is the clearest
/// App Review 5.2.3 problem in this app, and a flag-gated feature still ships the
/// code — so it is removed rather than disabled.
struct RootTabView: View {
    init() { Self.configureCompactTabBar() }

    /// Icon-only, translucent bar. UIKit owns the bar's height, so "compact"
    /// here means dropping the label row and letting content sit under a blur
    /// rather than a solid slab — the same read as Brave's bottom bar.
    ///
    /// `scrollEdgeAppearance` matters as much as the standard one: without it
    /// the bar turns opaque the moment a list reaches the bottom, which is the
    /// thing that makes a tab bar look heavy.
    private static func configureCompactTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

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
                .tabItem { Image(systemName: "house.fill") }
                .accessibilityLabel("Home")
                .tag(Tab.home)

            BrowserView(pendingAddress: $pendingAddress)
                .tabItem { Image(systemName: "globe") }
                .accessibilityLabel("Browser")
                .tag(Tab.browser)

            StreamView()
                .tabItem { Image(systemName: "link") }
                .accessibilityLabel("Stream")
                .tag(Tab.stream)

            LocalVideosView()
                .tabItem { Image(systemName: "film.fill") }
                .accessibilityLabel("Videos")
                .tag(Tab.videos)

            SettingsView()
                .tabItem { Image(systemName: "gearshape.fill") }
                .accessibilityLabel("Settings")
                .tag(Tab.settings)
        }
        .tint(PanuraTheme.accent)
    }
}
