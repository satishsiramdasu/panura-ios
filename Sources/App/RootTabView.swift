import SwiftUI

/// The app's shell: every destination stacked, one bar under them, and the
/// sections grid hanging above that bar.
///
/// Mirrors Android's `HomeScreen` after the nav rebuild — Home, Web and Videos
/// in the bar, Network Stream and Settings behind the grid. It is deliberately
/// NOT a `TabView`: five co-equal tabs said all five were places you switch
/// between, when only three are, and a `UITabBar` cannot draw the one-label
/// pill the bar now uses to say where you are.
///
/// Every destination stays composed and is hidden by opacity rather than being
/// rebuilt. The browser owns a live `WKWebView`, a page mid-load and a set of
/// detections; taking a trip to Home must not cost any of that.
///
/// iOS ships no download feature at all — saving streamed content is the
/// clearest App Review 5.2.3 problem in this app, and a flag-gated feature still
/// ships the code — so the bar has no Downloads seat to trade Videos for, as
/// Android's does inside the browser.
struct RootTabView: View {
    @State private var selection: AppDestination = {
        #if DEBUG
        // The screenshot run opens each screen by launching into it rather than
        // by tapping its way there — see ScreenshotMode.screen.
        if ScreenshotMode.isActive {
            switch ScreenshotMode.screen {
            case "web": return .web
            case "videos", "player": return .videos
            case "stream": return .stream
            case "settings": return .settings
            default: return .home
            }
        }
        #endif
        return .home
    }()
    @State private var showMenu = false
    /// Address typed on Home, waiting for the Browser to pick it up. The browser
    /// owns its WebView across switches, so the hand-off has to be state here
    /// rather than a fresh `BrowserView(url:)`.
    @State private var pendingAddress: String?
    @ObservedObject private var session = BrowserSession.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                destinations
                // Hidden while the browser is scrolled down, and only there: the
                // page needs the height, and every other destination is a list
                // that can reach its own end. The height animates away in place
                // rather than the bar sliding over the content, so nothing it
                // covers can end up unreachable.
                if barVisible {
                    AppBarRow(
                        selection: selection,
                        menuOpen: showMenu,
                        onSelect: select,
                        onToggleMenu: {
                            withAnimation(.easeOut(duration: 0.2)) { showMenu.toggle() }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: barVisible)

            if showMenu {
                // Scrim first: dismisses on tap without stealing the panel's own
                // taps. It stops at the bar, so the control that opened the panel
                // is the one that closes it.
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showMenu = false } }

                // Rests on the bar: the whole stack shares one bottom edge (see
                // below), so the panel only has to clear the bar's own height.
                AppMenuPanel(items: menuItems, current: selection)
                    .padding(.bottom, AppBarRow.totalHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // One bottom edge for everything in the stack — the screen's, not the
        // safe area's. Applied here rather than to the bar and the panel
        // separately: two views each ignoring the safe area on their own end up
        // measured against different bottoms, which is exactly how the panel
        // came to float an indicator's height above the bar.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// All five, always composed. The outgoing one keeps the higher `zIndex`
    /// until it has faded, or the incoming one shows through it.
    private var destinations: some View {
        ZStack {
            layer(.home) {
                HomeView(
                    onOpenBrowser: { address in
                        pendingAddress = address
                        select(.web)
                    },
                    onOpenSection: select
                )
            }
            layer(.web) {
                BrowserView(
                    pendingAddress: $pendingAddress,
                    onGoHome: { select(.home) },
                    onOpenSettings: { select(.settings) }
                )
            }
            layer(.videos) { LocalVideosView() }
            layer(.stream) { StreamView() }
            layer(.settings) { SettingsView() }
        }
    }

    @ViewBuilder
    private func layer<Content: View>(
        _ destination: AppDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let active = selection == destination
        content()
            .opacity(active ? 1 : 0)
            // A hidden layer must not eat taps meant for the visible one, and an
            // invisible screen should not be reachable by VoiceOver either.
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
    }

    /// The bar can only be hidden by the browser, and only while you are in it
    /// — leaving the Web tab must never strand it off screen.
    private var barVisible: Bool {
        selection != .web || session.barVisible || showMenu
    }

    private func select(_ destination: AppDestination) {
        session.showBar()
        withAnimation(.easeInOut(duration: 0.22)) {
            selection = destination
            showMenu = false
        }
    }

    /// What the grid holds: the destinations with no seat in the bar.
    ///
    /// Cast is deliberately NOT here. It is a control rather than a place, it
    /// has to be reachable from whatever screen you are on, and it now lives
    /// top-right in the header of every one of them — same slot as Android's.
    private var menuItems: [AppMenuPanel.Item] {
        [
            AppMenuPanel.Item(icon: "link", label: "Network Stream") { select(.stream) },
            AppMenuPanel.Item(icon: "gearshape.fill", label: "Settings") { select(.settings) },
        ]
    }
}
