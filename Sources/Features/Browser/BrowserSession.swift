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

    private init() {}

    func setPrivateMode(_ on: Bool) {
        guard privateMode != on else { return }
        privateMode = on
        // Shortcuts and resume points are explicit user actions and still
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
