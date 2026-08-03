import SwiftUI
import GoogleMobileAds

@main
struct PanuraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(CastManager.shared)
                .preferredColorScheme(nil) // follow system light/dark
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if FeatureFlags.adsEnabled {
            MobileAds.shared.start { _ in
                Task { @MainActor in AdManager.shared.preloadAll() }
            }
        }
        CastManager.shared.configure()
        // Detection rules can change server-side any day; refetch once per launch
        // (then the 6h TTL applies) so a fix lands without waiting the app out.
        ManifestStore.refreshOnLaunch()
        return true
    }

    /// The player drives orientation (allow-landscape / lock) through this.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.mask
    }
}
