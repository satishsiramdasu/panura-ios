import Foundation

/// Compile-time feature toggles.
///
/// There is deliberately no `downloadsEnabled` here: iOS ships no download
/// feature, and the code is gone rather than gated. Saving streamed content is
/// the clearest App Review 5.2.3 exposure in this app, so it is not a flag flip
/// away from returning.
enum FeatureFlags {
    static let adsEnabled = false

    /// The shell's `+` tab, listing IPTV and FTP.
    ///
    /// ⚠️ **Must be `false` for any App Store submission while those screens
    /// are still placeholders.** Guideline 2.1 App Completeness rejects an app
    /// with features that announce themselves and then do nothing, and a tab
    /// leading to "not built yet" is exactly that. It is on now so the shell
    /// can be looked at on a device; turn it off before attaching a build, or
    /// build the screens first.
    static let showsPlannedTabs = true
}
