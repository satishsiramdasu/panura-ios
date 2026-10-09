import SwiftUI

/// Whether the app header and the tab strip are on screen.
///
/// Home keeps both, always. It is a screen of cards you scan rather than a
/// document you read, and it is short — taking furniture away from it would buy
/// a few points of height and cost the one place the app says what it is.
///
/// Every other tab is a reading surface: a web page, a library of videos. There
/// the chrome earns its height or it goes. Leaving Home hides the header at
/// once, because you have just told the app where you want to be and the name
/// of the app is not it. Scrolling down then takes the tabs too, leaving the
/// screen's own bar — the browser's address row — as the only thing above the
/// content. Scrolling back up returns the tabs, and reaching the top returns
/// everything.
///
/// Two separate flags rather than one, because they come back at different
/// moments: the tabs return on any upward scroll, the header only at the top.
/// Collapsing them into one would mean either the header flickering back on
/// every small scroll up, or the tabs being unreachable without scrolling all
/// the way home.
@MainActor
final class ShellChrome: ObservableObject {
    static let shared = ShellChrome()

    @Published private(set) var headerVisible = true
    @Published private(set) var tabsVisible = true

    /// Whether the tab on screen hides its chrome at all. False on Home.
    private var scrollAway = false

    private init() {}

    private static let motion = Animation.easeOut(duration: 0.22)

    /// The tab changed. Home shows everything; anywhere else starts with the
    /// header already gone — the instant part of the brief, and the reason this
    /// is not simply driven by scroll position.
    func destinationChanged(to destination: AppDestination) {
        let away = destination != .home
        scrollAway = away
        withAnimation(Self.motion) {
            headerVisible = !away
            tabsVisible = true
        }
    }

    /// - Parameters:
    ///   - delta: points scrolled since the last report. Positive is downward
    ///     through the content.
    ///   - atTop: the content is against its top edge, bounce excluded.
    ///
    /// The 8-point threshold is the one `BrowserSession` already uses for the
    /// address bar: small enough to feel immediate, large enough that a page
    /// still settling does not flap the chrome.
    func scrolled(by delta: CGFloat, atTop: Bool) {
        guard scrollAway else { return }
        if atTop {
            guard !headerVisible || !tabsVisible else { return }
            withAnimation(Self.motion) {
                headerVisible = true
                tabsVisible = true
            }
            return
        }
        if delta > 8 {
            guard headerVisible || tabsVisible else { return }
            withAnimation(Self.motion) {
                headerVisible = false
                tabsVisible = false
            }
        } else if delta < -8 {
            // The tabs come back on the way up; the header waits for the top.
            // Otherwise the name of the app reappears every time somebody
            // nudges a page back a line.
            guard !tabsVisible else { return }
            withAnimation(Self.motion) { tabsVisible = true }
        }
    }

    /// A screen that is going away must not strand the chrome off screen.
    func reveal() {
        guard !headerVisible || !tabsVisible else { return }
        withAnimation(Self.motion) {
            headerVisible = true
            tabsVisible = true
        }
    }
}

/// Reports a SwiftUI scroll view's offset to `ShellChrome`.
///
/// The browser has no need of this — its scroll view is a real `UIScrollView`
/// and `WebViewContainer` already observes `contentOffset` for the address bar,
/// so it reports from there. This is for the screens built out of SwiftUI
/// scroll views, which expose nothing and have to be measured.
private struct ScrollAwayChrome: ViewModifier {
    @State private var last: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self,
                        // Negated so positive means "scrolled downward through
                        // the content", matching what the browser reports.
                        value: -geo.frame(in: .named(ScrollOffsetKey.space)).minY
                    )
                }
            )
            .onPreferenceChange(ScrollOffsetKey.self) { y in
                let delta = y - last
                last = y
                ShellChrome.shared.scrolled(by: delta, atTop: y <= 1)
            }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let space = "panura.scroll"
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Put this on the *content* inside a scroll view, and
    /// `scrollAwayContainer()` on the scroll view itself.
    func scrollAwayChrome() -> some View {
        modifier(ScrollAwayChrome())
    }

    /// The coordinate space the offset above is measured in.
    func scrollAwayContainer() -> some View {
        coordinateSpace(name: ScrollOffsetKey.space)
    }
}
