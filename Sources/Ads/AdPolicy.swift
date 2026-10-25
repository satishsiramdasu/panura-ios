import Foundation

/// When an ad is allowed, and nothing else.
///
/// Deliberately free of the ad SDK. Every rule about *whether* to show
/// something lives here, where it can be read in one screen and reasoned
/// about without Google's framework in the picture; `AdManager` owns only the
/// loading and presenting. The rules were argued over at length and the
/// reasoning is worth more than the code, so it is written down beside it.
///
/// **One interstitial clock** (docs/ads.md §1, revised 2026-10-25). Every
/// interstitial placement *and app open* reads and resets one shared clock,
/// whose gap is the manifest's country-tiered `gapSeconds`. The placements are
/// only triggers: an exit ad followed a minute later by a server open shows
/// nothing, because the gap has not passed. Rewarded keeps its own clock and
/// never waits on the interstitials — the person asked for it.
@MainActor
enum AdPolicy {
    /// The things that can show an ad.
    enum Placement: String, CaseIterable {
        /// Leaving the player — any player, from any tab.
        ///
        /// **On exit, not on a video ending.** In-player next and previous
        /// walk `PlayerPlaylist` without closing the screen, so a three-episode
        /// run is one ad on the way out rather than one between every pair.
        /// That was the whole difference between this and the most resented
        /// pattern in media apps, and the gap length could not have fixed it:
        /// episodes are 25 to 40 minutes, so any gap worth having is always
        /// already satisfied when one ends.
        ///
        /// It was browser-only for a while. Extending it to every engine
        /// sweeps in camera-roll videos too — somebody's own file, and still
        /// our player, which is the thing that was built.
        case player
        /// A cast that has been *confirmed* to be playing, before the cast
        /// controls appear. The best-placed ad in the app — the TV is
        /// handshaking anyway, so it costs no real time.
        case cast
        /// A server's listing has loaded after the person opened it from the
        /// Servers list, or after a refresh they pressed. An interstitial,
        /// after the listing and never in front of it — an ad between the tap
        /// and the thing asked for is an ad for waiting. It replaced the
        /// rewarded refresh wall.
        case servers
        /// A download was enqueued.
        case download
        /// Coming back to the app after time away. An app-open ad.
        ///
        /// Left out of the first design as the most resented format there
        /// is, and added later on request — so it is hedged on every side
        /// rather than fired on every launch. Never on a cold start, never
        /// after a glance at another app, never over a video or a cast. See
        /// `AdManager.showAppOpenIfDue`.
        case appOpen
        /// Converting a video from this phone for a Chromecast. Rewarded:
        /// the conversion is the reward, and it runs while the ad plays.
        ///
        /// No gap. Every conversion is real work done on request, and a copy
        /// already converted plays without asking again.
        case conversion

        /// How long before this placement may fire again.
        ///
        /// Fifteen minutes for the two interstitials (US/UK-tier default), an
        /// hour for the rewarded refresh regardless of country — that lever is
        /// about trust in a feature, not CPM. Neither binds as often as it
        /// looks.
        ///
        /// The player's is behind a *minute of playback and an exit*, so
        /// anybody watching something of normal length has an effective gap of
        /// however long that thing was. It bites on short clips opened and
        /// abandoned one after another, which is exactly when it should.
        /// Fifteen rather than ten not because ten fires too often, but
        /// because the cost of being wrong here is asymmetric: an ad too many
        /// is remembered and an ad too few is not noticed.
        ///
        /// The cast gap exists for channel zapping. Casting IPTV and changing
        /// channel sends a fresh load each time, and five channels in two
        /// minutes would otherwise be five interstitials.
        ///
        /// **Country-tiered**, via `AdCountryPolicy` — low-CPM markets get a
        /// shorter gap, because the fixed 15-minute floor was sized for
        /// countries where impressions are expensive enough that annoyance
        /// outweighs volume, and that trade is backwards everywhere else.
        /// This placement's own gap, on top of the shared one. Only app open
        /// has one: an hour, fixed, because it is the one ad nobody did
        /// anything to bring on.
        @MainActor var gap: TimeInterval {
            switch self {
            case .appOpen: return 60 * 60
            default: return 0
            }
        }

        /// Interstitials and app open share one clock; rewarded does not.
        var sharesClock: Bool { self != .conversion }

        fileprivate var lastShownKey: String { "ads.last." + rawValue }
    }

    private static let sharedKey = "ads.last.interstitial"

    private static func elapsed(since key: String) -> TimeInterval? {
        let last = UserDefaults.standard.double(forKey: key)
        return last > 0 ? Date().timeIntervalSince1970 - last : nil
    }

    // MARK: the first session

    private static let launchCountKey = "ads.launch_count"

    /// Counts this launch. Called once, at startup, before anything asks.
    static func noteLaunch() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: launchCountKey) + 1, forKey: launchCountKey)
    }

    /// Whether this is one of the first two launches.
    ///
    /// **The first two launches are ad-free, banner included** (docs/ads.md
    /// §7). Somebody who installs the app, tries it and comes back once sees
    /// nothing — and they were never going to earn anything either way.
    ///
    /// Counted in launches rather than measured with a clock, which is both
    /// simpler and strictly more generous: a timer can be burned by
    /// backgrounding the app for ten seconds to read a message, and "ads start
    /// the second time you open it" is a sentence anybody can check.
    ///
    /// Two consequences, both acceptable. App Review almost certainly sees no
    /// ads at all, since a reviewer works in one session — good for approval,
    /// and a reason the ad paths must be right before shipping rather than
    /// after. And day-one impressions from install-once-and-leave users are
    /// lost, which is close to nothing in revenue.
    static var isFirstSession: Bool {
        UserDefaults.standard.integer(forKey: launchCountKey) <= 2
    }

    // MARK: may we

    /// Whether `placement` may fire right now.
    static func allows(_ placement: Placement) -> Bool {
        guard FeatureFlags.adsEnabled, !isFirstSession else { return false }
        return remaining(placement) <= 0
    }

    /// Starts the clocks. Called when an ad is actually presented — never when
    /// one was merely requested, or a failed load would spend the gap and the
    /// next genuine chance with it.
    static func record(_ placement: Placement) {
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: placement.lastShownKey)
        if placement.sharesClock { UserDefaults.standard.set(now, forKey: sharedKey) }
    }

    /// How long until `placement` may fire again, or zero if it may now.
    /// For the ad-state panel: "blocked by a gap" and "never loaded" look
    /// identical from outside, and they need completely different fixes.
    static func remaining(_ placement: Placement) -> TimeInterval {
        var wait: TimeInterval = 0
        if placement.sharesClock, let since = elapsed(since: sharedKey) {
            wait = max(wait, AdCountryPolicy.gapSeconds - since)
        }
        if placement.gap > 0, let since = elapsed(since: placement.lastShownKey) {
            wait = max(wait, placement.gap - since)
        }
        return max(0, wait)
    }

    /// Whether anything may be drawn for ads at all — what the banner asks.
    ///
    /// The banner has no gap of its own: it is passive, it refreshes on the
    /// unit's own schedule, and the only questions are whether ads are on and
    /// whether this is somebody's first time in the app.
    static var allowsBanner: Bool {
        FeatureFlags.adsEnabled && !isFirstSession
    }

    // MARK: the qualifier

    /// Whether this much playback counts as "watched".
    ///
    /// The reason the browser interstitial has a qualifier at all: without
    /// one, a stream that dies after eight seconds still counts as playback
    /// ending, and the user gets an ad immediately after the app failed them.
    /// They were waiting on a video and got an advert for the privilege. That
    /// is the worst ad moment it is possible to build, and it would ship to
    /// everybody whose link expired.
    ///
    /// `AdCountryPolicy.minWatchSeconds` **or** a quarter of the duration,
    /// whichever comes first, so a ninety-second clip can still qualify while
    /// a forty-minute episode does not need ten minutes of credit. Sixty
    /// seconds in the default/high-CPM tier, thirty in the low-CPM one. Zero
    /// would drop the qualifier entirely, and is not used: a stream that
    /// dies after a few seconds would then earn an ad.
    static func watchedEnough(seconds: Double, duration: Double?) -> Bool {
        guard seconds.isFinite, seconds > 0 else { return false }
        let minWatch = AdCountryPolicy.minWatchSeconds
        if minWatch <= 0 { return true }
        if seconds >= minWatch { return true }
        guard let duration, duration.isFinite, duration > 0 else { return false }
        return seconds >= duration * 0.25
    }

    // MARK: housekeeping

    /// Forgets every clock. For Clear Data, and for anyone testing who does
    /// not want to wait an hour to see the next one.
    static func reset() {
        let defaults = UserDefaults.standard
        Placement.allCases.forEach { defaults.removeObject(forKey: $0.lastShownKey) }
        defaults.removeObject(forKey: sharedKey)
    }
}
