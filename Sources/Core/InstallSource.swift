import Foundation

/// Where this copy of the app came from.
///
/// One binary is uploaded and then both tested in TestFlight and, once
/// approved, released on the App Store, so the build itself cannot say. The
/// install can: iOS puts a receipt named `sandboxReceipt` in a TestFlight
/// install and one named `receipt` in an App Store install.
///
/// Apple does not promise that file name, so every doubt answers "not
/// TestFlight". The receipt must be named `sandboxReceipt`; an Xcode install
/// shares the name, and counts as a testing install too, which is right.
/// Anything this gets wrong leaves the tester screens hidden and the live ads
/// on, never the other way round.
enum InstallSource {
    static var isTestFlight: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard let url = Bundle.main.appStoreReceiptURL,
              url.lastPathComponent == "sandboxReceipt"
        else { return false }
        return true
        #endif
    }
}
