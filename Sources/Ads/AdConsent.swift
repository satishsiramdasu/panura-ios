import UIKit
import UserMessagingPlatform

/// The consent form, asked once per person and then remembered by Google.
///
/// **Not optional.** Since January 2024 AdMob requires a Google-certified
/// consent management platform to serve EEA and UK traffic, and without one it
/// simply stops serving those users — not degraded ads, none. For an app whose
/// audience is a diaspora, the UK share alone makes that the difference
/// between a banner that earns and a blank strip.
///
/// Google's own UMP SDK is that certified platform, it is free, and it ships
/// inside the GoogleMobileAds package already in this project. So this file is
/// small on purpose: all it does is ask the SDK whether a form is required,
/// show it when it is, and get out of the way.
///
/// Everything here is best-effort. A consent check that fails must never stop
/// the app starting — the cost of an error is non-personalised ads or no ads,
/// which is a revenue problem and not a user's problem.
enum AdConsent {
    /// Updates consent status and presents the form if one is owed.
    ///
    /// Awaited before `MobileAds.start`, because an ad requested before
    /// consent is resolved is an ad request Google may refuse outright in a
    /// consent region.
    @MainActor
    static func gather() async {
        let parameters = ConsentRequestParameters()
        // No `tagForUnderAgeOfConsent`: this app has no age signal and no
        // accounts, so claiming either answer would be a guess. Left unset,
        // which is what the SDK treats as "not declared".
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { _ in
                // The error is deliberately ignored. Its only causes are
                // network failure and misconfiguration, and neither is worth
                // blocking a launch over: the form will be asked for again
                // next time, and in the meantime the SDK's own stored status
                // decides what may be served.
                continuation.resume()
            }
        }
        await present()
    }

    /// Shows the form, if the SDK says one is required.
    @MainActor
    private static func present() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ConsentForm.loadAndPresentIfRequired(from: topViewController()) { _ in
                continuation.resume()
            }
        }
    }

    /// Whether ads may be requested at all under the consent the user gave.
    ///
    /// Google's answer, not ours — it folds in the region, the form's result
    /// and the stored purposes. Worth checking before deciding a blank banner
    /// is a bug.
    @MainActor
    static var canRequestAds: Bool {
        ConsentInformation.shared.canRequestAds
    }

    /// Lets somebody change their mind, for the privacy-options entry a
    /// consent region requires to stay reachable after the first answer.
    ///
    /// Not wired to a Settings row yet — it is only required where a form was
    /// shown, and the row should appear exactly there rather than confusing
    /// everybody else with an option that does nothing.
    @MainActor
    static func presentPrivacyOptions() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ConsentForm.presentPrivacyOptionsForm(from: topViewController()) { _ in
                continuation.resume()
            }
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
