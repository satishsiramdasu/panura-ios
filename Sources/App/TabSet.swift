import Foundation

/// Which tabs this person has in their strip, and which one the app opens on.
///
/// Three are always there — Home, Browser, Videos — because they are what the
/// app is for everybody. Everything else is opt-in: the `+` at the end of the
/// row offers what is left, and choosing one puts it in the strip for good and
/// takes you straight to it. When there is nothing left to offer, the `+` goes
/// away rather than opening an empty menu.
///
/// This is why the strip is a list and not a constant. A tab somebody added is
/// a tab they asked for, which is a much better reason for it to be taking up a
/// quarter of the row than our guess about who wants IPTV.
///
/// The ceiling is arithmetic, not a rule: `fixed + addable` is every tab there
/// can ever be, so the row cannot grow past five. Four and a half fit the
/// width — see `AppChrome.tabsPerRow` and `AppChrome.tabPeek`.
@MainActor
final class TabSet: ObservableObject {
    static let shared = TabSet()

    /// Always present, always in this order, never removable.
    ///
    /// IPTV used to be here and is not any more. Two reasons, and the product
    /// one came first: most people who open this app have no subscription to
    /// put in it, and a quarter of the row spent on a tab they will never
    /// press is worse than one tap for the people who will. The second is that
    /// the word is the one most likely to make an App Store reviewer go
    /// looking for a pirate service, and behind the `+` it is read in context
    /// — a thing somebody deliberately added, next to the line saying Panura
    /// supplies no channels — rather than being the first thing on screen.
    nonisolated static let fixed: [AppDestination] = [.home, .web, .videos]

    /// The pool the `+` offers from.
    ///
    /// One entry, because Servers is now one tab for everything with an
    /// address and a password behind it — a NAS, a playlist, an IPTV account.
    /// It is opt-in: somebody with any of those wants it permanently, and
    /// somebody with none should never have to look at it.
    ///
    /// Network Stream is deliberately not here either. It is a URL field and a
    /// Play button, used once and left; it has a card on Home and opens as a
    /// sheet from there, which is the right shape for somewhere you go and come
    /// straight back out of.
    nonisolated static var addable: [AppDestination] { [.ftp] }

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
    /// Everybody had IPTV in the strip, and the playlists they added are still
    /// there — they are inside Servers now. Without this the tab would simply
    /// vanish in an update and take a working subscription with it, as far as
    /// anybody could tell. A fresh install — which is what App Review always
    /// gets — never runs this and starts with the three.
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

        // Only for somebody who has used the app before. A first launch has
        // no stored tab of any kind, and seeding one there would be the
        // opposite of opt-in.
        let returning = defaults.object(forKey: storageKey) != nil
            || defaults.string(forKey: lastTabKey) != nil
        guard returning else { return }

        // Everybody returning gets Servers: either they had IPTV, which lives
        // in there now, or they had the Server tab, which is the same tab
        // under a wider name.
        var keys = defaults.stringArray(forKey: storageKey) ?? []
        keys.removeAll { $0 == AppDestination.iptv.key }
        if !keys.contains(AppDestination.ftp.key) { keys.append(AppDestination.ftp.key) }
        defaults.set(keys, forKey: storageKey)

        // And somebody who was last on the IPTV tab is sent to the tab that
        // now holds it, rather than to Home because the stored one is gone.
        if defaults.string(forKey: lastTabKey) == AppDestination.iptv.key {
            defaults.set(AppDestination.ftp.key, forKey: lastTabKey)
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
