import SwiftUI

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

    func setPrivateMode(_ on: Bool) {
        guard privateMode != on else { return }
        // The web view is rebuilt on a different data store, and it must not
        // come back holding the page it had. Cleared here rather than at each
        // call site so no future caller can forget.
        lastURL = nil
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
