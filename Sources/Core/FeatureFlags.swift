import Foundation

/// Compile-time feature toggles. Downloads and Ads are deferred for the initial
/// release; flip these to `true` to restore full parity with Android.
enum FeatureFlags {
    static let downloadsEnabled = false
    static let adsEnabled = false
}
