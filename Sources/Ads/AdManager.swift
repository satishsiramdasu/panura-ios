import UIKit
import GoogleMobileAds

/// Interstitial ads, one preloaded unit per placement — mirrors the Android
/// AdManager's four slots (player / browser / cast / downloads), each shown on
/// a *successful* action only.
@MainActor
final class AdManager: NSObject {
    static let shared = AdManager()

    enum Slot: CaseIterable {
        case player, browser, cast, downloads

        /// TODO: replace with real iOS AdMob interstitial unit IDs.
        var unitID: String {
            #if DEBUG
            return "ca-app-pub-3940256099942544/4411468910" // Google test interstitial
            #else
            switch self {
            case .player:    return "ca-app-pub-6998555111280991/0000000001"
            case .browser:   return "ca-app-pub-6998555111280991/0000000002"
            case .cast:      return "ca-app-pub-6998555111280991/0000000003"
            case .downloads: return "ca-app-pub-6998555111280991/0000000004"
            }
            #endif
        }
    }

    private var ads: [Slot: InterstitialAd] = [:]

    func preloadAll() { Slot.allCases.forEach(preload) }

    func preload(_ slot: Slot) {
        let request = Request()
        InterstitialAd.load(with: slot.unitID, request: request) { [weak self] ad, error in
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
