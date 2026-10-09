import UIKit
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
/// **It finds the real `UIScrollView` and watches that.** The first attempt
/// measured the content with a `GeometryReader` in a named coordinate space and
/// published the offset through a `PreferenceKey`, which is the usual SwiftUI
/// answer and did nothing at all here: the grid is a `LazyVGrid`, and a
/// preference written from the background of a lazy container is not reliably
/// republished as that container scrolls. There is no way to tell from the
/// SwiftUI side whether it will be.
///
/// A `ScrollView` is a `UIScrollView` with SwiftUI's layout inside it, so a
/// zero-size `UIView` dropped into the content can walk up its own superviews,
/// find it, and observe `contentOffset` directly — exactly what
/// `WebViewContainer` does for the browser's address bar, and that has worked
/// since the day it was written. One mechanism for both screens instead of two,
/// and the one that is left is the one that is not guessing.
private struct ScrollAwayChrome: ViewModifier {
    /// Which screen this is, so `ShellChrome` can ignore it while it is one of
    /// the composed-but-hidden layers.
    let destination: AppDestination

    func body(content: Content) -> some View {
        content.background(
            ScrollProbe(destination: destination)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}

private struct ScrollProbe: UIViewRepresentable {
    let destination: AppDestination

    func makeUIView(context: Context) -> ScrollProbeView {
        let view = ScrollProbeView()
        view.destination = destination
        return view
    }

    func updateUIView(_ view: ScrollProbeView, context: Context) {
        view.destination = destination
    }
}

/// Nothing to look at: it exists to be somewhere inside a `UIScrollView`.
private final class ScrollProbeView: UIView {
    var destination: AppDestination = .home
    private var observation: NSKeyValueObservation?
    private var last: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // Both, because which one lands after the scroll view exists depends on how
    // SwiftUI got round to hosting this, and attaching twice is prevented by
    // the nil check rather than by guessing right.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        attach()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attach()
    }

    private func attach() {
        guard observation == nil, let scroll = enclosingScrollView else { return }
        last = scroll.contentOffset.y
        // KVO rather than the delegate: SwiftUI owns the delegate, and taking
        // it would break its own scrolling.
        observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] observed, _ in
            self?.offsetChanged(observed)
        }
    }

    private var enclosingScrollView: UIScrollView? {
        var next = superview
        while let view = next {
            if let scroll = view as? UIScrollView { return scroll }
            next = view.superview
        }
        return nil
    }

    /// The same reading the browser takes, for the same reasons — see
    /// `WebViewContainer.scrolled`.
    private func offsetChanged(_ scroll: UIScrollView) {
        let y = scroll.contentOffset.y
        let delta = y - last
        last = y
        // The top is a state rather than a direction, and it is what brings the
        // whole shell back, so it is reported even though arriving there is not
        // a scroll upward.
        let atTop = y <= 0
        // Rubber-banding at the bottom is not a scroll downward; reading it as
        // one hides the chrome on a bounce.
        guard atTop || y < scroll.contentSize.height - scroll.bounds.height else { return }
        let target = destination
        let reported: CGFloat = atTop ? 0 : delta
        Task { @MainActor in
            ShellChrome.shared.scrolled(by: reported, atTop: atTop, from: target)
        }
    }
}

extension View {
    /// Put this on the content inside a `ScrollView`.
    func scrollAwayChrome(_ destination: AppDestination) -> some View {
        modifier(ScrollAwayChrome(destination: destination))
    }
}
