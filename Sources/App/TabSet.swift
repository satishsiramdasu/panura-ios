import Foundation

/// Which tabs this person has in their strip, and which one the app opens on.
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
    nonisolated static let fixed: [AppDestination] = [.home, .web, .videos]

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
    nonisolated static var addable: [AppDestination] {
        FeatureFlags.showsPlannedTabs ? [.iptv, .ftp] : []
    }

    nonisolated static let storageKey = "shell.added_tabs"
    nonisolated static let lastTabKey = "shell.last_tab"

    /// Whether the app opens on the tab it was left on. On by default — it is
    /// what every app with tabs does, and the alternative is throwing away
    /// something the user has already told us.
    nonisolated static let restoreKey = "restore_last_tab"

    @Published private(set) var added: [AppDestination]

    /// The strip, in order.
    var tabs: [AppDestination] { Self.fixed + added }

    /// What the `+` still has to offer. Empty means no `+`.
    var offerable: [AppDestination] {
        Self.addable.filter { !added.contains($0) }
    }

    private init() {
        added = Self.storedTabs()
    }

    /// The tabs that were added, as storage has them.
    ///
    /// Filtered against the pool as it stands now, not as it stood when they
    /// were written: a tab that has since been withdrawn — the flag turned off,
    /// a feature dropped — must not come back out of storage and put a seat in
    /// the row that leads nowhere.
    nonisolated static func storedTabs() -> [AppDestination] {
        let keys = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        let pool = addable
        return keys.compactMap(AppDestination.init(key:)).filter { pool.contains($0) }
    }

    /// The tab to open on.
    ///
    /// **Never the browser.** A browser tab restored on launch is an empty
    /// start page — the web view is not reopened on the page it was left on,
    /// because reloading a site unasked spends somebody's data on a guess and
    /// lands them on something they had finished with. So the app opens on
    /// Home, where that page is offered as a card they can take or ignore.
    /// Every other tab restores: Videos, and anything added from the `+`, is a
    /// place with its own content already waiting.
    ///
    /// `nonisolated` and reading storage directly rather than the instance, so
    /// the shell can ask for it while building its initial state.
    nonisolated static func openingTab() -> AppDestination {
        let defaults = UserDefaults.standard
        guard defaults.flag(restoreKey, default: true),
              let key = defaults.string(forKey: lastTabKey),
              let last = AppDestination(key: key),
              last != .web,
              (fixed + storedTabs()).contains(last)
        else { return .home }
        return last
    }

    /// Remembers where the user is, for the next launch.
    ///
    /// The browser is written down like anywhere else and simply not restored —
    /// recording where somebody actually was and deciding separately what to do
    /// with it beats pretending they were somewhere else.
    func remember(_ destination: AppDestination) {
        guard tabs.contains(destination) else { return }
        UserDefaults.standard.set(destination.key, forKey: Self.lastTabKey)
    }

    func add(_ destination: AppDestination) {
        guard Self.addable.contains(destination), !added.contains(destination) else { return }
        added.append(destination)
        UserDefaults.standard.set(added.map(\.key), forKey: Self.storageKey)
    }
}
