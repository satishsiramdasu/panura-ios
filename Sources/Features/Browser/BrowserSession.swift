import SwiftUI

/// The words both private-mode dialogs use.
///
/// Home's pill and the browser's panel switch the same thing with the same
/// consequence, and they used to describe it differently - different titles,
/// different buttons, and only one of them offering to keep the page. Two
/// screens describing one switch two ways is two features as far as anyone
/// reading them is concerned.
enum PrivateSwitch {
    static func title(turningOn: Bool) -> String {
        turningOn ? "Start private browsing?" : "Turn off private browsing?"
    }

    static func message(turningOn: Bool) -> String {
        turningOn
            ? "Private browsing starts a fresh session. Keep the page you are on, or close it."
            : "This session ends and history starts being recorded again. Keep the page you are on, or close it."
    }
}

/// Browser state that outlives the browser screen.
///
/// Two things need to be readable from outside `BrowserView`, and for the same
/// reason Android keeps them on a shared ViewModel: Home's address pill carries
/// the incognito toggle, and the app's one bottom bar hides while the browser is
/// scrolled — neither of those views owns the web view they describe.
@MainActor
final class BrowserSession: ObservableObject {
    static let shared = BrowserSession()

    /// Private browsing. The web view is rebuilt on a non-persistent data store
    /// when this flips, and history recording stops — the two halves of what
    /// "private" has to mean.
    @Published private(set) var privateMode = false

    /// False while the page is being scrolled down. The bar animates its height
    /// away in place rather than sliding over the content, so nothing it covers
    /// can end up out of reach.
    @Published var barVisible = true

    /// The page the browser is on, kept here rather than only on the model.
    ///
    /// Two things need it that do not own the web view. Home's pill can switch
    /// private mode and has no way to know the browser is mid-page, so the
    /// toggle used to close whatever was open without asking. And the web view
    /// is rebuilt often enough - private mode, two settings, an iPad resize -
    /// that `makeUIView` needs somewhere outside the view tree to read the page
    /// back from, or every rebuild lands on the start page.
    @Published private(set) var lastURL: URL?

    /// Whether there is a page worth warning about. The start page is not one.
    var hasPage: Bool { lastURL != nil && lastURL != WebViewContainer.startPage }

    func pageChanged(to url: URL?) {
        if lastURL != url { lastURL = url }
    }

    private init() {}

    /// - Parameter keepingPage: carry the open page across the switch.
    ///
    /// The web view is rebuilt on a different data store either way - that is
    /// what private mode *is* - and `makeUIView` reloads from `lastURL`. So
    /// keeping the page is simply not clearing it, and closing it is clearing
    /// it. Both directions offer both, because both directions cost the page
    /// and neither answer is obviously right: someone going private on a page
    /// usually wants to carry on reading it privately, and someone coming out
    /// may well want to bookmark what they were on.
    func setPrivateMode(_ on: Bool, keepingPage: Bool = false) {
        guard privateMode != on else { return }
        if !keepingPage { lastURL = nil }
        privateMode = on
        // Bookmarks and resume points are explicit user actions and still
        // persist; only the passive record stops.
        BrowsingStore.shared.recordHistory = !on
    }

    /// Called from the web view's scroll: down hides the bar, up brings it back.
    /// The threshold matches Android's 8px — small enough to feel immediate,
    /// large enough that a settling page does not flap the bar.
    func scrolled(by delta: CGFloat) {
        if delta > 8 {
            if barVisible { barVisible = false }
        } else if delta < -8 {
            if !barVisible { barVisible = true }
        }
    }

    /// Leaving the browser must not strand the bar off screen.
    func showBar() { barVisible = true }
}
