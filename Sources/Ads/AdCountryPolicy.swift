import Foundation
import StoreKit

/// Country-tiered ad pacing. CPM differs by an order of magnitude across
/// countries, so one global gap either wastes impressions in cheap markets or
/// annoys users in expensive ones. The tier table itself lives server-side,
/// in the manifest's `ads` block (`panura` repo, `.manifest-src/manifest.source.json`)
/// — a tier edit ships without an app release. This type only resolves the
/// viewer's own tier and caches it.
///
/// **Country source: the Store's storefront, not the device locale.** A VPN
/// changes the IP and can change the locale with one tap; it cannot change
/// which country's App Store the Apple ID is registered to. Locale is a
/// fallback only, for the case `Storefront.current` returns nil.
///
/// No country is ever sent anywhere — this reads Apple's on-device API and
/// the manifest, nothing else. See `docs/ads.md` section 12.
@MainActor
enum AdCountryPolicy {
    struct Tier {
        let gapSeconds: TimeInterval
        let minWatchSeconds: TimeInterval
    }

    /// Matches `AdPolicy`'s historical hardcoded values, so a launch before
    /// `refresh()` completes (or a manifest fetch that fails) behaves exactly
    /// as the app did before tiers existed.
    private static var current = Tier(gapSeconds: 15 * 60, minWatchSeconds: 60)

    static var gapSeconds: TimeInterval { current.gapSeconds }
    static var minWatchSeconds: TimeInterval { current.minWatchSeconds }

    /// Resolves the tier and caches it. Call once at launch; safe to call
    /// again (e.g. after a manifest refetch) since it only overwrites the
    /// cache. `AdPolicy.allows`/`watchedEnough` are synchronous and called
    /// from hot paths, so the lookup can't happen per call.
    static func refresh() async {
        guard FeatureFlags.adsEnabled else { return }
        guard let ads = await ManifestStore.adsConfig() else { return }
        guard let country = await storefrontCountry() ?? Locale.current.region?.identifier
        else { return }

        let defaultGap = (ads["defaultGapSeconds"] as? Double) ?? current.gapSeconds
        let defaultWatch = (ads["defaultMinWatchSeconds"] as? Double) ?? current.minWatchSeconds
        var tier = Tier(gapSeconds: defaultGap, minWatchSeconds: defaultWatch)

        if let tiers = ads["tiers"] as? [[String: Any]] {
            for t in tiers {
                guard let countries = t["countries"] as? [String],
                      countries.contains(country) else { continue }
                tier = Tier(
                    gapSeconds: (t["gapSeconds"] as? Double) ?? defaultGap,
                    minWatchSeconds: (t["minWatchSeconds"] as? Double) ?? defaultWatch
                )
                break
            }
        }
        current = tier
    }

    /// The Apple ID's billing country — set once, when the account was
    /// created, and not something a VPN touches.
    private static func storefrontCountry() async -> String? {
        await Storefront.current?.countryCode
    }
}
