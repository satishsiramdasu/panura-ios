import Foundation

/// Where this copy of the app came from.
///
/// One binary is uploaded and then both tested in TestFlight and, once
/// approved, released on the App Store, so the build itself cannot say. The
/// install can: iOS puts a receipt named `sandboxReceipt` in a TestFlight
/// install and one named `receipt` in an App Store install.
///
/// Apple does not promise that file name, so every doubt answers "not
/// TestFlight". The receipt must be named `sandboxReceipt` **and** exist on
/// disk — which also rules out an Xcode install, whose receipt URL has the
/// same name but no file behind it. Anything this gets wrong therefore leaves
/// the tester screens hidden and the live ads on, never the other way round.
enum InstallSource {
    static var isTestFlight: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard let url = Bundle.main.appStoreReceiptURL,
              url.lastPathComponent == "sandboxReceipt"
        else { return false }
        return FileManager.default.fileExists(atPath: url.path)
        #endif
    }
}
