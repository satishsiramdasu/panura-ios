import Foundation

/// Which tabs this person has in their strip.
///
/// Three are always there — Home, Browser, Videos — because they are what the
/// app is. Everything else is opt-in: the `+` at the end of the row offers what
/// is left, and choosing one puts it in the strip for good and takes you
/// straight to it. When there is nothing left to offer, the `+` goes away
/// rather than opening an empty menu.
///
/// This is why the strip is a list and not a constant. A tab somebody added is
/// a tab they asked for, which is a much better reason for it to be taking up a
/// quarter of the row than our guess about who wants IPTV.
///
/// The ceiling is arithmetic, not a rule: `fixed + addable` is every tab there
/// can ever be, so the row cannot grow past five while the pool is two. Four
/// fill the width and a fifth peeks — see `AppChrome.tabsPerRow`.
@MainActor
final class TabSet: ObservableObject {
    static let shared = TabSet()

    /// Always present, always in this order, never removable.
    static let fixed: [AppDestination] = [.home, .web, .videos]

    /// The pool the `+` offers from.
    ///
    /// Empty when `FeatureFlags.showsPlannedTabs` is off, which is what must
    /// happen for a submission — and an empty pool means no `+`, so the flag
    /// removes the whole mechanism rather than leaving a button that offers
    /// nothing.
    ///
    /// Network Stream is deliberately not here. It is a URL field and a Play
    /// button, used once and left; it has a card on Home and opens as a sheet
    /// from there, which is the right shape for somewhere you go and come
    /// straight back out of.
    static var addable: [AppDestination] {
        FeatureFlags.showsPlannedTabs ? [.iptv, .ftp] : []
    }

    private static let storageKey = "shell.added_tabs"

    @Published private(set) var added: [AppDestination]

    /// The strip, in order.
    var tabs: [AppDestination] { Self.fixed + added }

    /// What the `+` still has to offer. Empty means no `+`.
    var offerable: [AppDestination] {
        Self.addable.filter { !added.contains($0) }
    }

    private init() {
        let keys = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        // Filtered against the pool as it stands now, not as it stood when this
        // was written: a tab that has since been withdrawn — the flag turned
        // off, a feature dropped — must not come back out of storage and put a
        // seat in the row that leads nowhere.
        let pool = Self.addable
        added = keys.compactMap(AppDestination.init(key:)).filter { pool.contains($0) }
    }

    func add(_ destination: AppDestination) {
        guard Self.addable.contains(destination), !added.contains(destination) else { return }
        added.append(destination)
        UserDefaults.standard.set(added.map(\.key), forKey: Self.storageKey)
    }
}
