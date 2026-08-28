import SwiftUI
import GoogleMobileAds

@main
struct PanuraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// "dark" | "light" | "system". Dark by default, as on Android, where the
    /// amber-on-near-black scheme is the one the app is designed around; the
    /// light scheme exists and is complete, but it is not the house style.
    @AppStorage("appearance") private var appearance = "dark"

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(CastManager.shared)
                // One tint for every system control — switches, pickers, the
                // text cursor — so nothing keeps iOS blue next to the amber.
                .tint(PanuraTheme.accent)
                .background(PanuraTheme.background)
                .preferredColorScheme(
                    appearance == "light" ? .light : (appearance == "dark" ? .dark : nil)
                )
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
