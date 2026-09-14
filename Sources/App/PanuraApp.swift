import SwiftUI
import FirebaseCore
import FirebaseCrashlytics
import FirebaseAnalytics

@main
struct PanuraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(CastManager.shared)
                // One tint for every system control — switches, pickers, the
                // text cursor — so nothing keeps iOS blue next to the amber.
                .tint(PanuraTheme.accent)
                .background(PanuraTheme.background)
                // Dark only, as the Android app ships: every surface, every
                // hex in PanuraTheme and the launch screen are the one scheme.
                // There is no light build to switch to.
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // First, so a crash anywhere later in launch is still reported.
        startFirebase()
        // Ads start themselves, after the ATT prompt: the SDK must not be
        // started before that answer exists, or the first requests go out
        // personalised regardless of it. AdManager does nothing at all while
        // FeatureFlags.adsEnabled is false.
        Task { @MainActor in await AdManager.shared.startIfEnabled() }
        CastManager.shared.configure()
        // Detection rules can change server-side any day; refetch once per launch
        // (then the 6h TTL applies) so a fix lands without waiting the app out.
        ManifestStore.refreshOnLaunch()
        return true
    }

    /// Crashlytics and Analytics — only when GoogleService-Info.plist reached the
    /// bundle.
    ///
    /// The plist is not in the repo; CI writes it from a secret. A build without
    /// that secret would otherwise crash at launch inside `configure()`, which is
    /// a poor way to learn a secret was missing. Sideload test builds made
    /// without it simply run with no Firebase at all.
    ///
    /// Both modules are touched by name, not merely linked: they register from
    /// `+load` in static libraries, and a module nothing references is one the
    /// linker is entitled to drop.
    private func startFirebase() {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        FirebaseApp.configure()
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        Analytics.setAnalyticsCollectionEnabled(true)
    }

    /// The player drives orientation (allow-landscape / lock) through this.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.mask
    }
}
