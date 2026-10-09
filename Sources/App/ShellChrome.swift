import SwiftUI

/// Whether the app header and the tab strip are on screen.
///
/// Home keeps both, always. It is a screen of cards you scan rather than a
/// document you read, and it is short — taking furniture away from it would buy
/// a few points of height and cost the one place the app says what it is.
///
/// Every other tab is a reading surface: a web page, a library of videos. There
/// the chrome earns its height or it goes — but only ever because the reader
/// asked. Scrolling down takes the header and then the tabs, leaving the
/// screen's own bar — the browser's address row, the Videos toolbar — as the
/// only thing above the content. Scrolling back up returns the tabs, and
/// reaching the top returns everything.
///
/// **A tab switch hides nothing.** It used to: arriving anywhere but Home
/// dropped the header at once, on the reasoning that you had just said where
/// you wanted to be. In the hand it read as the app twitching — you press
/// Videos and the thing you pressed through slides away under your finger,
/// before you have looked at anything. Worse, the first scroll report from the
/// screen you landed on put it straight back, so a switch was a slide up and a
/// slide down for nothing. Chrome moves on scroll and on nothing else now.
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

    /// Which tab is on screen.
    ///
    /// Every destination in the shell stays composed — the browser keeps its
    /// web view, Videos keeps its grid — so all of them are live enough to
    /// report a scroll, and a screen nobody is looking at sits at its top edge
    /// reporting exactly that. Left ungated, the hidden Videos grid undid the
    /// browser's hidden chrome and vice versa. A report that does not come from
    /// here is dropped.
    private var current: AppDestination = .home

    /// Whether the tab on screen hides its chrome at all. False on Home.
    private var scrollAway = false

    private init() {}

    private static let motion = Animation.easeOut(duration: 0.22)

    /// The tab changed: everything comes back, and nothing slides.
    ///
    /// Unanimated on purpose. The chrome is either already there, in which case
    /// there is nothing to show, or it is away because the last screen was
    /// scrolled down — and sliding it back in would animate furniture that
    /// belongs to the screen you just left.
    func destinationChanged(to destination: AppDestination) {
        current = destination
        scrollAway = destination != .home
        headerVisible = true
        tabsVisible = true
    }

    /// - Parameters:
    ///   - delta: points scrolled since the last report. Positive is downward
    ///     through the content.
    ///   - atTop: the content is against its top edge, bounce excluded.
    ///   - destination: the screen reporting. Dropped unless it is the one on
    ///     screen — see `current`.
    ///
    /// The 8-point threshold is the one `BrowserSession` already uses for the
    /// address bar: small enough to feel immediate, large enough that a page
    /// still settling does not flap the chrome.
    func scrolled(by delta: CGFloat, atTop: Bool, from destination: AppDestination) {
        guard destination == current, scrollAway else { return }
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
}

/// Reports a SwiftUI scroll view's offset to `ShellChrome`.
///
/// The browser has no need of this — its scroll view is a real `UIScrollView`
/// and `WebViewContainer` already observes `contentOffset` for the address bar,
/// so it reports from there. This is for the screens built out of SwiftUI
/// scroll views, which expose nothing and have to be measured.
private struct ScrollAwayChrome: ViewModifier {
    /// Which screen this is, so `ShellChrome` can ignore it while it is one of
    /// the composed-but-hidden layers.
    let destination: AppDestination
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
                ShellChrome.shared.scrolled(by: delta, atTop: y <= 1, from: destination)
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
    func scrollAwayChrome(_ destination: AppDestination) -> some View {
        modifier(ScrollAwayChrome(destination: destination))
    }

    /// The coordinate space the offset above is measured in.
    func scrollAwayContainer() -> some View {
        coordinateSpace(name: ScrollOffsetKey.space)
    }
}
