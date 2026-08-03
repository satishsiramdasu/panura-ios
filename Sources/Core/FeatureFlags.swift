import Foundation

/// Compile-time feature toggles.
///
/// There is deliberately no `downloadsEnabled` here: iOS ships no download
/// feature, and the code is gone rather than gated. Saving streamed content is
/// the clearest App Review 5.2.3 exposure in this app, so it is not a flag flip
/// away from returning.
enum FeatureFlags {
    static let adsEnabled = false
}
