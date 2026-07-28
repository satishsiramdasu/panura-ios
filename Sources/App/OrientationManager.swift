import UIKit

/// App-wide interface-orientation gate.
///
/// The tab UI is happy in any orientation (Info.plist allows portrait +
/// landscape), but the player wants two extra powers Info.plist alone can't give:
///   1. bias to landscape when a video opens, and
///   2. *lock* to whatever orientation the user is currently holding.
///
/// iOS routes `application(_:supportedInterfaceOrientationsFor:)` through here,
/// and `apply()` nudges the active scene to re-evaluate immediately (iOS 16
/// `requestGeometryUpdate`) instead of waiting for the next physical rotation.
enum OrientationManager {
    /// The mask the AppDelegate hands back to UIKit. Default matches Info.plist.
    static var mask: UIInterfaceOrientationMask = .all {
        didSet { guard oldValue != mask else { return }; apply() }
    }

    /// Allow free rotation (player open, not locked).
    static func allowAll() { mask = .allButUpsideDown }

    /// Restore the app-wide default (player closed).
    static func reset() { mask = .all }

    /// Pin to the orientation currently on screen — the player's lock button.
    static func lockCurrent() {
        let o = currentInterfaceOrientation
        switch o {
        case .landscapeLeft:  mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        case .portraitUpsideDown: mask = .portraitUpsideDown
        default: mask = .portrait
        }
    }

    static var isLocked: Bool {
        // A single-orientation mask means the user locked it.
        ![.all, .allButUpsideDown].contains(mask)
    }

    private static var currentInterfaceOrientation: UIInterfaceOrientation {
        activeScene?.interfaceOrientation ?? .portrait
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private static func apply() {
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
