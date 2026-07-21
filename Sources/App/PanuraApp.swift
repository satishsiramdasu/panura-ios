import SwiftUI
import GoogleMobileAds

@main
struct PanuraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(CastManager.shared)
                .environmentObject(DownloadManager.shared)
                .preferredColorScheme(nil) // follow system light/dark
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MobileAds.shared.start { _ in
            Task { @MainActor in AdManager.shared.preloadAll() }
        }
        CastManager.shared.configure()
        return true
    }
}
