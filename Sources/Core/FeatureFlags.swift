import Foundation

/// Compile-time feature toggles.
///
/// There is deliberately no `downloadsEnabled` here: iOS ships no download
/// feature, and the code is gone rather than gated. Saving streamed content is
/// the clearest App Review 5.2.3 exposure in this app, so it is not a flag flip
/// away from returning.
enum FeatureFlags {
    static let adsEnabled = true

    /// Serve Google's **test** units instead of ours, in a build that is not
    /// a debug build.
    ///
    /// `#if DEBUG` is not enough on its own, because TestFlight builds use the
    /// Release configuration: a TestFlight build of this would otherwise load
    /// live units, and tapping your own live ad is invalid activity — it gets
    /// units limited and accounts flagged. So verification on a real device
    /// needs this, not a debug build.
    ///
    /// It also makes the banner and the rewarded unlock testable *before*
    /// those two units exist in AdMob, which they do not yet.
    ///
    /// ⚠️ **Set this false in the release that is submitted.** With it true
    /// the app earns nothing: Google's test units pay zero. It is the one flag
    /// here whose wrong value is silent — the ads look right and the revenue
    /// is zero — so it is checked at the top of
    /// `store/app-store-listing.md`'s release list.
    static let adsUseTestUnits = true
}
