import Combine
import SwiftUI

/// Which screen may draw the app's one banner.
///
/// **There is exactly one `BannerView` for the life of the process**, owned by
/// `AdManager`. That is deliberate: making a new one per appearance fires an ad
/// request on every tab switch, inside the 30-second floor for repeat requests
/// on a unit — invalid-traffic territory — and a view that short-lived never
/// survives to the refresh cycle where banner revenue actually accumulates. So
/// `BannerStrip` re-parents the same view rather than creating one.
///
/// Which leaves one problem: two strips on screen at once would both try to
/// adopt it, and whichever ran its `updateUIView` last would win. That is a
/// race, and the losing screen shows an empty gap where an ad should be.
///
/// A claim settles it. The shell's strip draws while nothing is claimed; a page
/// presented over the shell claims the banner on the way in and releases it on
/// the way out. Both strips watch this object, so the hand-over is a single
/// state change — one strip's `if` goes false as the other's goes true — and
/// there is never a moment when two of them want the same view.
///
/// Claims are not stacked. One page over the shell is the whole of the current
/// need, and a stack would be state to get wrong for a case that does not
/// arise: the cast page is presented from the shell, never from another page
/// that has a banner of its own.
@MainActor
final class BannerSlot: ObservableObject {
    static let shared = BannerSlot()

    private init() {}

    /// Who holds the banner. nil is the app shell, which is where it lives
    /// unless something has taken it.
    @Published private(set) var holder: String?

    func claim(_ who: String) {
        holder = who
    }

    /// Released by name, so a screen going away late cannot take the banner
    /// off whatever claimed it in the meantime.
    func release(_ who: String) {
        guard holder == who else { return }
        holder = nil
    }
}
