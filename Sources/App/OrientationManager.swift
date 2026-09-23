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
    /// The mask the AppDelegate hands back to UIKit. Narrower than Info.plist on
    /// a phone, which declares landscape for the player's sake - see `reset`.
    static var mask: UIInterfaceOrientationMask = defaultMask {
        didSet { guard oldValue != mask else { return }; apply() }
    }

    /// What the app allows with no player open. Also the launch value: `reset`
    /// runs when a player closes, so setting it only there would leave the
    /// first run of the app free to rotate until something had been played.
    private static var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    /// Allow free rotation (player open, not locked).
    static func allowAll() { mask = .allButUpsideDown }

    /// Restore the app-wide default (player closed).
    ///
    /// **Portrait on a phone, any orientation on an iPad.** Nobody browses the
    /// web sideways on a phone, and every screen in the app pays for the
    /// possibility: the header, the pill, the drawer and the Explore grid are
    /// all laid out for a tall narrow window, and a landscape phone is a wide
    /// short one with the keyboard taking most of it.
    ///
    /// This is the app's chrome only. The player is untouched - it calls
    /// `allowAll`, `applyVideoOrientation`, `rotate` and `lockCurrent` for
    /// itself, and landscape stays in `UISupportedInterfaceOrientations`
    /// because the plist is the ceiling: take landscape out of it and the
    /// player cannot ask for it either.
    static func reset() { mask = defaultMask }

    /// Auto-orient to match a video's shape (portrait clip → portrait, wide clip
    /// → landscape). Pins the family, like the manual rotate.
    static func applyVideoOrientation(portrait: Bool) {
        // Nothing to apply where the mask is ignored. Turning the *content* to
        // match a video's shape unasked would spin the picture under someone
        // who only pressed play, so the iPad letterboxes and leaves the turn to
        // the button.
        guard honoursMask else { return }
        mask = portrait ? .portrait : .landscape
    }

    /// Whether the system will act on `mask` at all.
    ///
    /// **False on iPad.** iPadOS ignores `supportedInterfaceOrientations` and
    /// `requestGeometryUpdate` for any app that supports multitasking, which
    /// this one does: `UIRequiresFullScreen` is unset and all four orientations
    /// are declared, both deliberately. So on an iPad the player's rotate
    /// button did nothing whatever - it set a mask nothing was going to read.
    ///
    /// The sanctioned fix is `UIRequiresFullScreen = true`, which costs Split
    /// View and Stage Manager across the whole app and is deprecated in iPadOS
    /// 26. `PlayerView` turns its own picture instead: no system involvement,
    /// nothing outside the player affected, and it survives the deprecation.
    static var honoursMask: Bool {
        UIDevice.current.userInterfaceIdiom != .pad
    }

    /// Manual rotate button — flip the pinned orientation family (portrait ⇄
    /// landscape) and force it. Because the resulting mask is a single family the
    /// app stays pinned there, so this rotates the player even when the device's
    /// auto-rotate lock is on. Mirrors Android's `RotationState.rotate()`.
    static func rotate() {
        mask = currentInterfaceOrientation.isLandscape ? .portrait : .landscape
    }

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
        // A single-orientation mask means the user locked it. Only meaningful
        // while the player is open: with the player closed a phone sits at
        // `.portrait`, which is the default rather than a lock.
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
