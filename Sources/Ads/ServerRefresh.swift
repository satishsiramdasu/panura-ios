import Foundation

/// When a playlist server's catalogue has to be refreshed, and when refreshing
/// it costs an ad.
///
/// One timestamp per server answers all three rules:
///
/// ```
/// < 1 h      refresh is free        — a retry is never punished
/// 1 h – 24 h refresh shows an ad    — voluntary
/// > 24 h     refresh is required    — the catalogue is not shown at all
/// ```
///
/// **Its own clock, not `IPTVStore.fetchedAt`.** That was the obvious
/// candidate and it is wrong: `load` already goes back to the network for
/// anything older than `IPTVStore.freshness` — three hours — all by itself, so
/// `fetchedAt` is reset silently on nearly every open and a 24-hour wall built
/// on it would never appear. This records something different: the last time
/// the *user* refreshed, which is the last time an ad was shown or waived.
///
/// Playlist servers only. An SMB or SFTP listing is fetched live every time a
/// folder is opened, so "refresh" there is just re-listing — a daily ad to
/// re-read your own NAS is a toll with a nicer name.
@MainActor
enum ServerRefresh {
    /// After this, the catalogue is not shown until it is refreshed.
    static let expiry: TimeInterval = 24 * 60 * 60
    /// Inside this, refreshing is free however many times it is pressed.
    static let free: TimeInterval = 60 * 60

    private static func key(_ id: UUID) -> String { "server.refreshed." + id.uuidString }

    static func lastRefresh(_ id: UUID) -> Date? {
        let seconds = UserDefaults.standard.double(forKey: key(id))
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// Records a refresh that actually happened.
    static func stamp(_ id: UUID) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key(id))
    }

    /// Starts the clock, if it is not already running.
    ///
    /// Called on the first successful load of a server — the clock has to
    /// begin somewhere or `lastRefresh` stays nil and the wall never arrives.
    ///
    /// **"If first" is the whole point.** `IPTVStore.load` goes back to the
    /// network by itself for anything older than three hours and sets
    /// `fetchedAt` as it does. If that also moved this clock, it would be
    /// reset silently on nearly every open and 24 hours would never elapse.
    /// Only `stamp` — a refresh the user asked for — moves it after this.
    static func stampIfFirst(_ id: UUID) {
        guard lastRefresh(id) == nil else { return }
        stamp(id)
    }

    /// Drops a removed server's clock, so adding the same address back does
    /// not inherit a wall from the one before it.
    static func forget(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
    }

    /// Whether this catalogue may be shown at all.
    ///
    /// A server that has never been refreshed is **not** expired: the first
    /// open is a plain load, and meeting a wall before ever seeing a channel
    /// would read as a broken app rather than as a stale catalogue. The clock
    /// starts at the first successful load.
    static func isExpired(_ id: UUID) -> Bool {
        guard FeatureFlags.adsEnabled, let last = lastRefresh(id) else { return false }
        return Date().timeIntervalSince(last) > expiry
    }

    /// Whether a refresh pressed right now should play an ad first.
    ///
    /// False inside the free hour, and false when there is no clock yet —
    /// nothing has been earned from somebody who has not finished opening the
    /// thing once.
    static func adDue(_ id: UUID) -> Bool {
        guard FeatureFlags.adsEnabled, let last = lastRefresh(id) else { return false }
        return Date().timeIntervalSince(last) >= free
    }

    /// How old the catalogue is, for the wall to say so. Vague on purpose: the
    /// exact minute is not the point and "2 days" reads better than a date.
    static func ageDescription(_ id: UUID) -> String? {
        guard let last = lastRefresh(id) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: last, relativeTo: Date())
    }
}
