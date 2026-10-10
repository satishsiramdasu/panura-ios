import Foundation

/// Which tabs this person has in their strip, and which one the app opens on.
///
/// Four, all fixed: Home, Browser, Videos, Servers. That is the whole app, so
/// `addable` is empty and the `+` the strip used to end with is gone — see
/// `fixed` and `addable` for why each of those is the case.
///
/// It stays a list rather than a constant because the opt-in machinery is
/// still here and costs a filter and an array. The `+` reappears on its own
/// the moment `addable` has anything in it, and a tab somebody added is a much
/// better reason for it to take a fifth of the row than our guess about who
/// wants it.
///
/// The ceiling is arithmetic, not a rule: `fixed + addable` is every tab there
/// can ever be. Four and a half fit the width — see `AppChrome.tabsPerRow` and
/// `AppChrome.tabPeek`.
@MainActor
final class TabSet: ObservableObject {
    static let shared = TabSet()

    /// Always present, always in this order, never removable.
    ///
    /// Four, and the fourth is Servers. It was briefly opt-in, which was the
    /// right answer while it meant IPTV and nothing else — a quarter of the
    /// row spent on a subscription most people do not have. Now that one tab
    /// holds every kind of place you sign into, it is general enough to earn
    /// a seat: a NAS, a playlist, an account, and whatever is added next all
    /// arrive inside it rather than as another tab.
    ///
    /// It also takes the IPTV naming problem off the strip for good. The word
    /// is inside, on the screen that explains Panura supplies no channels,
    /// which is the only place it was ever doing useful work.
    nonisolated static let fixed: [AppDestination] = [.home, .web, .videos, .ftp]

    /// The pool the `+` offers from. Empty, so there is no `+`.
    ///
    /// Four tabs is the whole app: Home, the browser, this phone's videos, and
    /// everything you sign into. Nothing is left over to offer, and a button
    /// that opens a menu of nothing is worse than no button — which is why the
    /// strip drops it on its own when this is empty.
    ///
    /// The machinery stays. It costs a filter and an array, and the next thing
    /// that deserves a seat but not everybody's seat goes in here.
    ///
    /// Network Stream will not be that thing. It is a URL field and a Play
    /// button, used once and left; it has a card on Home and opens as a sheet
    /// from there, which is the right shape for somewhere you go and come
    /// straight back out of.
    nonisolated static var addable: [AppDestination] { [] }

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

    /// One-time, for installs from before Servers swallowed the IPTV tab.
    ///
    /// The playlists somebody added are still there — they are inside Servers
    /// now — but the tab they were reached through is gone, and the app would
    /// otherwise open on Home with no explanation.
    nonisolated static let migratedKey = "shell.servers_merge_migrated"

    private init() {
        added = Self.storedTabs()
    }

    /// Runs before anything reads the stored tabs, which is why it lives in
    /// `storedTabs()` rather than in `init`: the shell asks `openingTab()` for
    /// its initial state, and that is a static call that may land before this
    /// object exists.
    nonisolated static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        // Nothing to add to the strip any more — Servers is one of the
        // four. The one thing still worth carrying across is where somebody
        // was: last on the IPTV tab means last in what is now Servers, and
        // without this they would be sent to Home because the tab they
        // remember no longer exists.
        if defaults.string(forKey: lastTabKey) == AppDestination.iptv.key {
            defaults.set(AppDestination.ftp.key, forKey: lastTabKey)
        }
        // And the stored strip loses a tab that is now fixed, so it cannot
        // come back out of storage and sit in the row twice.
        if var keys = defaults.stringArray(forKey: storageKey) {
            keys.removeAll { $0 == AppDestination.iptv.key || $0 == AppDestination.ftp.key }
            defaults.set(keys, forKey: storageKey)
        }
    }

    /// The tabs that were added, as storage has them.
    ///
    /// Filtered against the pool as it stands now, not as it stood when they
    /// were written — which covers a tab since withdrawn, and covered IPTV
    /// back when it was one of the fixed three and could otherwise have come
    /// out of storage and sat in the strip a second time.
    nonisolated static func storedTabs() -> [AppDestination] {
        migrateIfNeeded()
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
