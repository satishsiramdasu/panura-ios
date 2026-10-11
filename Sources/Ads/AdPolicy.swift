import Foundation

/// When an ad is allowed, and nothing else.
///
/// Deliberately free of the ad SDK. Every rule about *whether* to show
/// something lives here, where it can be read in one screen and reasoned
/// about without Google's framework in the picture; `AdManager` owns only the
/// loading and presenting. The rules were argued over at length and the
/// reasoning is worth more than the code, so it is written down beside it.
///
/// **There is no global floor between placements, on purpose.** Asked for,
/// considered, rejected: the rewarded ad is a button the user pressed, so
/// suppressing it because an unrelated interstitial fired two minutes ago
/// would withhold a feature they explicitly asked for. The three placements
/// are three different actions and each keeps its own clock.
@MainActor
enum AdPolicy {
    /// The three things that can show an ad. One clock each.
    enum Placement: String, CaseIterable {
        /// End of playback in the browser's player, before returning to the
        /// page. A natural break: the video finished, nobody is mid-gesture.
        case browserPlayer
        /// A cast that has been *confirmed* to be playing, before the cast
        /// controls appear. The best-placed ad in the app — the TV is
        /// handshaking anyway, so it costs no real time.
        case cast
        /// Loading the contents of a server. Rewarded, so opt-in.
        case servers

        /// How long before this placement may fire again.
        ///
        /// Ten minutes for the two interstitials, an hour for the rewarded
        /// unlock. Neither number binds as often as it looks: the browser one
        /// is gated behind a finished video, so somebody watching a 25-minute
        /// episode has an effective gap of 25 minutes, and it only bites on
        /// short clips watched back to back — which is exactly when it should.
        /// The cast gap exists for channel zapping: casting IPTV and changing
        /// channel fires a load each time, and five channels in two minutes
        /// would otherwise be five interstitials.
        var gap: TimeInterval {
            switch self {
            case .browserPlayer, .cast: return 10 * 60
            case .servers: return 60 * 60
            }
        }

        fileprivate var lastShownKey: String { "ads.last." + rawValue }
    }

    // MARK: the first session

    private static let launchCountKey = "ads.launch_count"

    /// Counts this launch. Called once, at startup, before anything asks.
    static func noteLaunch() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: launchCountKey) + 1, forKey: launchCountKey)
    }

    /// Whether this is the first time the app has been opened.
    ///
    /// **The whole first session is ad-free, banner included.** Somebody who
    /// installs the app, watches one thing and leaves sees nothing — and they
    /// were never going to earn anything either way.
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
        UserDefaults.standard.integer(forKey: launchCountKey) <= 1
    }

    // MARK: may we

    /// Whether `placement` may fire right now.
    static func allows(_ placement: Placement) -> Bool {
        guard FeatureFlags.adsEnabled, !isFirstSession else { return false }
        let last = UserDefaults.standard.double(forKey: placement.lastShownKey)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= placement.gap
    }

    /// Starts `placement`'s clock. Called when an ad is actually presented —
    /// never when one was merely requested, or a failed load would spend the
    /// gap and the next genuine chance with it.
    static func record(_ placement: Placement) {
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: placement.lastShownKey
        )
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
    /// Sixty seconds **or** a quarter of the duration, whichever comes first,
    /// so a ninety-second clip can still qualify while a forty-minute episode
    /// does not need ten minutes of credit.
    static func watchedEnough(seconds: Double, duration: Double?) -> Bool {
        guard seconds.isFinite, seconds > 0 else { return false }
        if seconds >= 60 { return true }
        guard let duration, duration.isFinite, duration > 0 else { return false }
        return seconds >= duration * 0.25
    }

    // MARK: housekeeping

    /// Forgets every clock. For Clear Data, and for anyone testing who does
    /// not want to wait an hour to see the next one.
    static func reset() {
        let defaults = UserDefaults.standard
        Placement.allCases.forEach { defaults.removeObject(forKey: $0.lastShownKey) }
    }
}
