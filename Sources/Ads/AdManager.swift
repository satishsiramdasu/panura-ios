import UIKit
import AppTrackingTransparency
import AdSupport
import GoogleMobileAds

/// Interstitial ads, one preloaded unit per placement.
///
/// Three placements rather than Android's four: its downloads slot has no
/// counterpart here, and neither does its rewarded unit, which gates converting
/// an HLS download into an MP4. Separate units per placement are not decoration
/// — AdMob reports per unit, and one merged unit would make "which screen earns"
/// unanswerable.
///
/// Every ad is shown after a *successful* action, never before or during one.
@MainActor
final class AdManager: NSObject {
    static let shared = AdManager()

    enum Slot: CaseIterable {
        case player, browser, cast

        /// Live units, from the iOS app in AdMob. Debug builds never touch them
        /// — shipping Google's test unit in a release is an AdMob policy
        /// violation, and hitting a live unit while testing is the other half
        /// of the same rule.
        var unitID: String {
            #if DEBUG
            return "ca-app-pub-3940256099942544/4411468910" // Google test interstitial
            #else
            switch self {
            case .player:  return "ca-app-pub-6998555111280991/4427286974"
            case .browser: return "ca-app-pub-6998555111280991/6832395366"
            case .cast:    return "ca-app-pub-6998555111280991/6201839976"
            }
            #endif
        }
    }

    private var ads: [Slot: InterstitialAd] = [:]
    /// True once ATT has been answered (either way) and the SDK has started.
    private var ready = false

    /// Asks for tracking permission, starts the SDK, then fills the slots.
    ///
    /// Order matters and the order is Apple's: the ATT prompt cannot be raised
    /// until the app is actually in front of someone — a request made while the
    /// app is still launching is returned `.notDetermined` without ever showing
    /// a dialog, and the permission is then unaskable for that install.
    func startIfEnabled() async {
        guard FeatureFlags.adsEnabled, !ready else { return }
        await requestTrackingPermission()
        MobileAds.shared.start(completionHandler: nil)
        ready = true
        preloadAll()
    }

    /// Raised once, ever. A refusal is not an error and not a reason to ask
    /// again: the answer lives in Settings from then on, and re-prompting is
    /// both futile and a rejection reason.
    private func requestTrackingPermission() async {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        // A beat after launch, or the prompt races the first frame and is
        // dismissed by the window coming up underneath it.
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }

    /// Personalised only with explicit permission. Anything else — refused, not
    /// yet asked, or restricted by policy — gets `npa=1`, which is what keeps
    /// the privacy manifest's `NSPrivacyTracking` false.
    private func makeRequest() -> Request {
        let request = Request()
        guard ATTrackingManager.trackingAuthorizationStatus != .authorized else { return request }
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }

    func preloadAll() { Slot.allCases.forEach(preload) }

    func preload(_ slot: Slot) {
        guard FeatureFlags.adsEnabled, ready else { return }
        InterstitialAd.load(with: slot.unitID, request: makeRequest()) { [weak self] ad, error in
            guard let ad, error == nil else { return }
            Task { @MainActor in self?.ads[slot] = ad }
        }
    }

    func showInterstitial(_ slot: Slot) {
        guard FeatureFlags.adsEnabled else { return }
        guard let ad = ads[slot], let root = Self.topViewController() else {
            preload(slot); return
        }
        ad.present(from: root)
        ads[slot] = nil
        preload(slot) // reload for next time
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
