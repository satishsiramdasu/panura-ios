import UIKit
import AppTrackingTransparency
import AdSupport
import GoogleMobileAds

/// Loads and presents ads. Whether one is *allowed* is `AdPolicy`'s question.
///
/// Three formats and no others. Interstitials fire at two natural breaks — a
/// finished video in the browser's player, and a confirmed cast — the rewarded
/// unit unlocks server content because the user asked it to, and the banner
/// earns passively at the bottom edge. App-open ads and mid-task interstitials
/// are deliberately absent: they are where accidental clicks, invalid-traffic
/// flags and uninstalls come from.
///
/// Separate units per placement are not decoration — AdMob reports per unit,
/// and one merged unit would make "which screen earns" unanswerable.
///
/// Every ad is shown after a *successful* action, never before or during one.
@MainActor
final class AdManager: NSObject {
    static let shared = AdManager()

    enum Slot: CaseIterable {
        case player, cast

        /// Live units, from the iOS app in AdMob. Debug builds never touch
        /// them — shipping Google's test unit in a release is an AdMob policy
        /// violation, and hitting a live unit while testing is the other half
        /// of the same rule.
        var unitID: String {
            #if DEBUG
            return AdManager.testInterstitialUnitID
            #else
            guard !FeatureFlags.adsUseTestUnits else { return AdManager.testInterstitialUnitID }
            switch self {
            case .player:  return "ca-app-pub-6998555111280991/4427286974"
            case .cast:    return "ca-app-pub-6998555111280991/6201839976"
            }
            #endif
        }

        /// Which clock this slot answers to.
        ///
        /// AdMob also holds a third interstitial unit, "browser"
        /// (`…/6832395366`), which the player exit ran on for a while. It is
        /// deliberately unused: the exit ad belongs to every engine's player,
        /// and it is reported under the unit that says so.
        var placement: AdPolicy.Placement? {
            switch self {
            case .player: return .player
            case .cast:   return .cast
            }
        }
    }

    // Google's own sample units. Safe to tap, pay nothing, always fill.
    //
    // `nonisolated`, because this class is `@MainActor` and so are its statics
    // by inheritance — while `Slot` is a plain nested enum and is not. `Slot.unitID`
    // reading a main-actor constant is a Swift 6 error, and the same pattern
    // is why `TabSet`'s statics carry the keyword.
    nonisolated static let testInterstitialUnitID = "ca-app-pub-3940256099942544/4411468910"
    nonisolated static let testRewardedUnitID = "ca-app-pub-3940256099942544/1712485313"
    nonisolated static let testBannerUnitID = "ca-app-pub-3940256099942544/2435281174"
    nonisolated static let testAppOpenUnitID = "ca-app-pub-3940256099942544/5575463023"

    /// The rewarded unit, which unlocks server content.
    ///
    /// "Server Ads" in AdMob.
    static var rewardedUnitID: String {
        #if DEBUG
        return testRewardedUnitID
        #else
        guard !FeatureFlags.adsUseTestUnits else { return testRewardedUnitID }
        return "ca-app-pub-6998555111280991/3135868525"
        #endif
    }

    /// "App Open" in AdMob.
    static var appOpenUnitID: String {
        #if DEBUG
        return testAppOpenUnitID
        #else
        guard !FeatureFlags.adsUseTestUnits else { return testAppOpenUnitID }
        return "ca-app-pub-6998555111280991/6221286156"
        #endif
    }

    private var appOpen: AppOpenAd?
    /// An app-open ad is good for four hours; one held longer earns nothing.
    private var appOpenLoadedAt: Date?
    /// When the app last left the foreground, or nil if it has not since the
    /// last return.
    private var backgroundedAt: Date?
    private var watchingForeground = false

    private var ads: [Slot: InterstitialAd] = [:]
    private var rewarded: RewardedAd?
    /// True once `MobileAds` has finished initialising. **Not** "we have
    /// asked it to": the SDK's configuration arrives asynchronously, and a
    /// request made before it lands comes back empty.
    private var ready = false
    /// True from the first `startIfEnabled` onwards, so a second call does not
    /// start a second consent round while the first is still in flight.
    /// `ready` cannot do that job any more — it now lands much later.
    private var starting = false
    /// One full-screen ad at a time. Two presentations racing is a black
    /// screen, and both of these can be triggered by things happening at once
    /// — a cast confirming while a player is closing.
    private var presenting = false
    /// Runs when the ad currently up is dismissed. How the cast controls are
    /// sequenced behind the cast interstitial.
    private var onDismiss: (() -> Void)?

    /// Asks for tracking permission, starts the SDK, then fills the slots.
    ///
    /// Order matters and the order is Apple's: the ATT prompt cannot be raised
    /// until the app is actually in front of someone — a request made while
    /// the app is still launching is returned `.notDetermined` without ever
    /// showing a dialog, and the permission is then unaskable for that
    /// install.
    ///
    /// Consent comes first regardless. Without a certified CMP, AdMob stops
    /// serving EEA and UK traffic altogether, so a form that has not been
    /// answered is worth more than a few seconds of earlier preloading.
    func startIfEnabled() async {
        guard FeatureFlags.adsEnabled, !starting else { return }
        starting = true
        // Consent first, but never fatally. A UMP call that does not come back
        // would stall this function, and with it every interstitial and the
        // rewarded unit — while the banner, which waits on none of it, carried
        // on working. That asymmetry is exactly what a stuck consent step
        // looks like from the outside, and it is not worth risking for a step
        // that is best-effort by design.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await AdConsent.gather() }
            group.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000) }
            _ = await group.next()
            group.cancelAll()
        }
        await requestTrackingPermission()
        // **Ads are loaded after `start` returns, not after the call is made.**
        // The mediation configuration arrives over the network, and an
        // `InterstitialAd.load` issued before it lands goes out before the SDK
        // has it and fails silently — which is why a first player-exit showed
        // no ad while the banner, built later when a screen first needed it,
        // always had one. `await` is what makes that ordering automatic.
        _ = await MobileAds.shared.start()
        ready = true
        preloadAll()
    }

    /// Raised once, ever — and only when personalised ads are actually wanted.
    ///
    /// **The guard is not an optimisation, it is what keeps the app alive.**
    /// iOS terminates a process that calls this with no
    /// `NSUserTrackingUsageDescription` in `Info.plist`, instantly and with no
    /// alert, the same way a missing `NSCameraUsageDescription` does. That key
    /// is deliberately absent — App Store Connect refuses a build carrying it
    /// unless the privacy answers declare tracking, which this app does not do
    /// — so asking without it is a launch crash half a second in. It shipped
    /// exactly once, the moment ads were switched on.
    ///
    /// A refusal is not an error and not a reason to ask again: the answer
    /// lives in Settings from then on, and re-prompting is both futile and a
    /// rejection reason.
    private func requestTrackingPermission() async {
        guard FeatureFlags.adsPersonalised else { return }
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        // A beat after launch, or the prompt races the first frame and is
        // dismissed by the window coming up underneath it.
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }

    /// Personalised only when asked for *and* explicitly permitted. Anything
    /// else — not wanted, refused, never asked, or restricted by policy — gets
    /// `npa=1`, which is what keeps the privacy manifest's `NSPrivacyTracking`
    /// false.
    ///
    /// Reading `trackingAuthorizationStatus` is safe without the usage string;
    /// only *requesting* is fatal. But it is skipped anyway when personalised
    /// ads are off, because then the answer cannot change what is sent.
    func makeRequest() -> Request {
        let request = Request()
        if FeatureFlags.adsPersonalised,
           ATTrackingManager.trackingAuthorizationStatus == .authorized {
            return request
        }
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }

    // MARK: interstitials

    func preloadAll() {
        Slot.allCases.filter { $0.placement != nil }.forEach(preload)
        preloadRewarded()
        preloadAppOpen()
        watchForeground()
    }

    /// How many times a slot's load has failed in a row, so a retry can back
    /// off instead of hammering a unit that is not filling.
    private var loadFailures: [Slot: Int] = [:]

    func preload(_ slot: Slot) {
        guard FeatureFlags.adsEnabled, ready, slot.placement != nil, ads[slot] == nil else { return }
        InterstitialAd.load(with: slot.unitID, request: makeRequest()) { [weak self] ad, error in
            Task { @MainActor in
                guard let self else { return }
                guard let ad, error == nil else {
                    // **Retried, because the old code only tried again after a
                    // missed impression.** One failed load at launch — no
                    // network yet, no fill, the SDK a moment behind — left the
                    // slot empty until the user finished a video, got no ad,
                    // and that miss queued the next attempt. The first ad of
                    // every install was spent discovering the load had failed.
                    let failures = (self.loadFailures[slot] ?? 0) + 1
                    self.loadFailures[slot] = failures
                    self.log("interstitial \(slot) load failed (\(failures)): \(error?.localizedDescription ?? "no ad")")
                    guard failures <= 4 else { return }
                    let delay = UInt64(min(120, 15 << (failures - 1))) * 1_000_000_000
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: delay)
                        self.preload(slot)
                    }
                    return
                }
                self.loadFailures[slot] = 0
                ad.fullScreenContentDelegate = self
                self.ads[slot] = ad
            }
        }
    }

    /// Ad failures are otherwise invisible: every one of them is a silent
    /// no-op by design, so without this there is no way to tell an ad that
    /// was not due from one that never loaded.
    private func log(_ message: String) {
        #if DEBUG
        print("[ads] " + message)
        #endif
    }

    /// Shows `slot` if its clock allows, then runs `then` — whether an ad
    /// appeared or not.
    ///
    /// `then` always runs, which is the contract that lets the cast path
    /// sequence its controls behind this without having to know whether an ad
    /// was due. An ad that cannot be shown must never swallow the thing the
    /// user was actually doing.
    func showInterstitial(_ slot: Slot, then: (() -> Void)? = nil) {
        guard let placement = slot.placement,
              AdPolicy.allows(placement),
              !presenting,
              let ad = ads[slot],
              let root = Self.topViewController()
        else {
            log("no interstitial for \(slot): loaded=\(ads[slot] != nil) presenting=\(presenting) ready=\(ready)")
            then?()
            preload(slot)
            return
        }
        presenting = true
        onDismiss = then
        AdPolicy.record(placement)
        ad.present(from: root)
        ads[slot] = nil
        preload(slot) // reload for next time
    }

    /// An interstitial owed by a screen that has to disappear first.
    ///
    /// The player is a full-screen cover presented by the root view, and a
    /// second presentation from that same presenter while the cover is still
    /// up does nothing at all — the same trap `PlaybackSession` works around
    /// for the opposite direction. So the player asks on its way out and the
    /// shell flushes it from the cover's `onDismiss`, which SwiftUI runs once
    /// the dismissal has finished.
    private var queued: Slot?

    func queue(_ slot: Slot) {
        guard let placement = slot.placement, AdPolicy.allows(placement) else { return }
        queued = slot
    }

    /// Shows whatever `queue` was promised. Called from the player cover's
    /// `onDismiss`; harmless when nothing is waiting, which is most closes.
    func flushQueued() {
        guard let slot = queued else { return }
        queued = nil
        showInterstitial(slot)
    }

    // MARK: rewarded

    /// Loaded with the `async` form rather than a completion handler — it is
    /// the one Google documents for `RewardedAd`, and a documented signature
    /// beats one inferred from `InterstitialAd`'s.
    private func preloadRewarded(attempt: Int = 1) {
        guard FeatureFlags.adsEnabled, ready, rewarded == nil, !Self.rewardedUnitID.isEmpty else { return }
        Task {
            do {
                let ad = try await RewardedAd.load(
                    with: Self.rewardedUnitID,
                    request: makeRequest()
                )
                ad.fullScreenContentDelegate = self
                rewarded = ad
            } catch {
                log("rewarded load failed (\(attempt)): \(error.localizedDescription)")
                guard attempt <= 4 else { return }
                try? await Task.sleep(nanoseconds: UInt64(min(120, 15 << (attempt - 1))) * 1_000_000_000)
                preloadRewarded(attempt: attempt + 1)
            }
        }
    }

    /// Plays the rewarded ad and grants the unlock.
    ///
    /// **`granted` is true when no ad could be shown at all** — no fill, no
    /// network, no unit configured, ads switched off. Fill is our problem, not
    /// the user's: a server they added, on hardware they own, must never stay
    /// shut because an ad network had nothing to serve. It is also true when
    /// the clock says no ad is due, because then there is nothing to earn.
    ///
    /// False only when somebody opened the ad and closed it early. They
    /// declined a bargain they were offered; nothing is taken away, and they
    /// can press again.
    func showRewarded(then granted: @escaping (Bool) -> Void) {
        guard FeatureFlags.adsEnabled, AdPolicy.allows(.servers), !presenting,
              let ad = rewarded, let root = Self.topViewController()
        else {
            granted(true)
            preloadRewarded()
            return
        }
        var earned = false
        presenting = true
        onDismiss = {
            granted(earned)
            // Only a watched ad spends the hour. Closing it early leaves the
            // clock alone so the next attempt still has something to offer.
            if earned { AdPolicy.record(.servers) }
        }
        ad.present(from: root) { earned = true }
        rewarded = nil
        preloadRewarded()
    }

    // MARK: app open

    private func preloadAppOpen(attempt: Int = 1) {
        guard FeatureFlags.adsEnabled, ready, appOpen == nil else { return }
        Task {
            do {
                let ad = try await AppOpenAd.load(
                    with: Self.appOpenUnitID,
                    request: makeRequest()
                )
                ad.fullScreenContentDelegate = self
                appOpen = ad
                appOpenLoadedAt = Date()
            } catch {
                log("app-open load failed (\(attempt)): \(error.localizedDescription)")
                guard attempt <= 4 else { return }
                try? await Task.sleep(nanoseconds: UInt64(min(120, 15 << (attempt - 1))) * 1_000_000_000)
                preloadAppOpen(attempt: attempt + 1)
            }
        }
    }

    private func watchForeground() {
        guard !watchingForeground else { return }
        watchingForeground = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.backgroundedAt = Date() }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showAppOpenIfDue() }
        }
    }

    /// Shows the app-open ad on a return to the app, if every hedge allows.
    ///
    /// **Never on a cold start.** Nothing is loaded that early, and holding
    /// the first screen back for an ad is the version of this format people
    /// uninstall over. It only ever greets a return.
    ///
    /// **Not after a glance away.** Half a minute out, at least: replying to a
    /// message and coming back is not opening the app. That also keeps it off
    /// the return from a tapped ad, which leaves the app the same way.
    ///
    /// **Not over a video or a cast.** Coming back to something playing — in
    /// the player, in Picture in Picture, on the television — is coming back
    /// to use a control, and an ad in front of the pause button is the worst
    /// place there is for one.
    private func showAppOpenIfDue() {
        guard let left = backgroundedAt else { return }
        backgroundedAt = nil
        guard Date().timeIntervalSince(left) >= 30 else { return }

        // Four hours is the format's shelf life. A stale one is dropped and
        // replaced rather than shown for nothing.
        if let loaded = appOpenLoadedAt, Date().timeIntervalSince(loaded) > 4 * 60 * 60 {
            appOpen = nil
            appOpenLoadedAt = nil
        }
        guard FeatureFlags.adsEnabled, AdPolicy.allows(.appOpen), !presenting, queued == nil,
              !PlaybackSession.shared.isPlayingSomething,
              !CastManager.shared.isCasting, !PanuraCastManager.shared.isCasting,
              let ad = appOpen, let root = Self.topViewController()
        else {
            preloadAppOpen()
            return
        }
        presenting = true
        onDismiss = nil
        AdPolicy.record(.appOpen)
        ad.present(from: root)
        appOpen = nil
        appOpenLoadedAt = nil
        preloadAppOpen()
    }

    // MARK: banner

    /// The app's one banner, kept here for the life of the process.
    ///
    /// **One long-lived view, never rebuilt per screen.** Tearing it down and
    /// remaking it on each tab switch fires a fresh request every time, and
    /// switching tabs is a two-second action: that lands well inside the
    /// 30-second floor for repeat requests on a unit, which is
    /// invalid-traffic territory. A short-lived view also never survives long
    /// enough to reach the server-side refresh cycle where banner revenue
    /// actually accumulates.
    ///
    /// **Refresh is 30 seconds, set on the unit in the AdMob console — not
    /// here.** There is deliberately no refresh code, which is exactly why
    /// the decision needs writing down somewhere: 30 rather than the usual 60
    /// because banner revenue tracks *visible seconds*, and this app has
    /// unusually few of them. The player hides the banner and the player is
    /// where the time goes, so a session leaves only two to four minutes of
    /// banner-visible time. A shorter cycle converts more of what little there
    /// is — eCPM dips as it shortens, but not proportionally. In an app where
    /// somebody sits on one screen for twenty minutes the session is not the
    /// constraint and 60 is fine; here it is the constraint.
    ///
    /// 30 is also the floor: below it, repeat requests on one unit are
    /// invalid-traffic territory — the same number quoted above, for the same
    /// reason.
    private(set) var banner: BannerView?

    /// "Banner" in AdMob. Its 30-second refresh is set there, not here.
    static var bannerUnitID: String {
        #if DEBUG
        return testBannerUnitID
        #else
        guard !FeatureFlags.adsUseTestUnits else { return testBannerUnitID }
        return "ca-app-pub-6998555111280991/5744975130"
        #endif
    }

    /// Hands back the banner, making it on first ask.
    func bannerView(width: CGFloat, root: UIViewController?) -> BannerView? {
        guard AdPolicy.allowsBanner, !Self.bannerUnitID.isEmpty, width > 0 else { return nil }
        if let banner {
            banner.rootViewController = root ?? banner.rootViewController
            return banner
        }
        let view = BannerView()
        // `currentOrientationAnchoredAdaptiveBanner(width:)` is confirmed by
        // the v12 migration guide as the rename of
        // `GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth`. Set as
        // a property rather than through an initialiser, because that is what
        // Google's own sample does and `BannerView(adSize:)` is not documented
        // for v12.
        //
        // Not the `large` variant: it runs to about 100 points on a phone, and
        // this banner pushes every screen's content up on every tab.
        view.adSize = currentOrientationAnchoredAdaptiveBanner(width: width)
        view.adUnitID = Self.bannerUnitID
        view.rootViewController = root
        view.load(makeRequest())
        banner = view
        return view
    }

    // MARK: what state everything is in

    /// Every gate an ad has to pass, as text. Read by the ad-state panel in
    /// About.
    ///
    /// **This exists because the failures are invisible.** Every one of them
    /// is a deliberate silent no-op — an ad that is not due, not loaded, not
    /// filled, or a session that is somebody's first — and from outside the
    /// app all of them look the same: no ad. On a sideloaded or TestFlight
    /// build there is no console either, so without this the only way to tell
    /// a 15-minute gap from an SDK that never started is to read the source
    /// and guess which.
    ///
    /// `ready` is the one worth looking at first. It is false until
    /// `MobileAds` finishes initialising, nothing preloads while it is false,
    /// and the banner does not depend on it — so "banners fine, interstitials
    /// never" is exactly what it looks like.
    struct Diagnostic: Identifiable {
        /// The label, which is unique, which makes it the id.
        let id: String
        let value: String
    }

    var diagnostics: [Diagnostic] {
        func clock(_ placement: AdPolicy.Placement) -> String {
            let left = AdPolicy.remaining(placement)
            guard left > 0 else { return "ready" }
            return "\(Int(left / 60) + 1) min to go"
        }
        let rewardedState = Self.rewardedUnitID.isEmpty
            ? "no unit set"
            : (rewarded != nil ? "loaded" : "empty")
        return [
            Diagnostic(id: "Ads enabled", value: FeatureFlags.adsEnabled ? "yes" : "no"),
            Diagnostic(id: "Units", value: FeatureFlags.adsUseTestUnits ? "Google test" : "live"),
            Diagnostic(id: "Session", value: AdPolicy.isFirstSession ? "first — all ads off" : "ads on"),
            Diagnostic(id: "Consent", value: AdConsent.canRequestAds ? "may request" : "not yet"),
            Diagnostic(id: "SDK ready", value: ready ? "yes" : "no — nothing can preload"),
            Diagnostic(id: "Player ad", value: ads[.player] != nil ? "loaded" : "empty"),
            Diagnostic(id: "Cast ad", value: ads[.cast] != nil ? "loaded" : "empty"),
            Diagnostic(id: "Rewarded", value: rewardedState),
            Diagnostic(id: "App-open ad", value: appOpen != nil ? "loaded" : "empty"),
            Diagnostic(id: "Player gap", value: clock(.player)),
            Diagnostic(id: "Cast gap", value: clock(.cast)),
            Diagnostic(id: "Refresh gap", value: clock(.servers)),
            Diagnostic(id: "App-open gap", value: clock(.appOpen)),
            Diagnostic(
                id: "Country tier",
                value: "\(Int(AdCountryPolicy.gapSeconds / 60))min gap, "
                    + "\(Int(AdCountryPolicy.minWatchSeconds))s qualifier"
            ),
        ]
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - presentation

extension AdManager: FullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        presenting = false
        let next = onDismiss
        onDismiss = nil
        next?()
    }

    /// A failure to present is a dismissal as far as the app is concerned: the
    /// thing the user was doing still has to happen.
    func ad(
        _ ad: FullScreenPresentingAd,
        didFailToPresentFullScreenContentWithError error: Error
    ) {
        presenting = false
        let next = onDismiss
        onDismiss = nil
        next?()
    }
}
