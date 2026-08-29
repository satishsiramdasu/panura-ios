import SwiftUI

/// The app's palette, ported value for value from Android's
/// `core/ui/theme/Color.kt` — amber on near-black.
///
/// iOS had a purple accent of its own, which made the two apps look like
/// different products; every hex here is the one Android ships.
///
/// **Dark only, by design.** Android's light scheme exists but the app is not
/// what it is in it, and the launch screen, the player and every surface below
/// are built for this one. `PanuraApp` forces `.dark` and `Info.plist` declares
/// `UIUserInterfaceStyle: Dark`, so nothing here needs a second value: what is
/// written is what ships.
///
/// Material's own names are kept — `surfaceContainer`, `onSurfaceVariant`,
/// `accentSoft` for `secondaryContainer` — because the Android side is the
/// reference, and a renamed token is one more thing to translate when comparing
/// the same screen on two phones.
enum PanuraTheme {
    // MARK: brand

    /// Amber 700. What everything selected, active or tappable wears.
    static let accent = Color(hex: 0xFFB300)
    static let onAccent = Color(hex: 0x3D2000)
    static let accentContainer = Color(hex: 0x5A3800)
    static let onAccentContainer = Color(hex: 0xFFDEA3)

    /// The selected-pill fill: Material's `secondaryContainer`, which is what
    /// Android's bar, chips and menu cells use to mark "here".
    static let accentSoft = Color(hex: 0x553D00)
    static let onAccentSoft = Color(hex: 0xFBD891)

    // MARK: surfaces

    static let background = Color(hex: 0x0F0F0E)
    static let onBackground = Color.white
    static let surface = background
    static let onSurface = onBackground
    /// Inputs and inert wells — the address pill's fill.
    static let surfaceVariant = Color(hex: 0x1C1C1A)
    /// Secondary text. White at 60% on Android, not a grey.
    static let onSurfaceVariant = Color.white.opacity(0.6)
    /// Bars and panels: the header, the bottom bar, the found bar, the menus.
    static let surfaceContainer = Color(hex: 0x181817)
    static let surfaceContainerHigh = Color(hex: 0x1E1E1D)
    static let surfaceContainerHighest = Color(hex: 0x252524)
    static let outline = Color(hex: 0x706050)
    static let outlineVariant = Color(hex: 0x3A3020)

    // MARK: status

    static let error = Color(hex: 0xFF8A80)
    /// Sizes, durations — information rather than a verdict. Material's
    /// tertiary, so it reads as distinct from the accent beside it.
    static let tertiary = Color(hex: 0xCCBE90)
    /// A probe that came back alive.
    static let success = Color(hex: 0x81C784)

    // MARK: incognito

    /// Android repaints the whole browser violet in private mode. iOS tints the
    /// pill and the menu's private row with the same values rather than swapping
    /// a scheme — the browser is one screen here, not a nav graph.
    static let incognito = Color(hex: 0xC7A9FF)
    static let incognitoContainer = Color(hex: 0x3B1F7A)
    static let incognitoSurface = Color(hex: 0x241F30)
    /// Bars and fields in private mode — one step up from `incognitoSurface`,
    /// the same relationship `surfaceContainer` has to `background`.
    static let incognitoSurfaceHigh = Color(hex: 0x2E2740)

    // MARK: shape

    static let cornerLarge: CGFloat = 28
    static let cornerMedium: CGFloat = 16
}

extension Color {
    /// `0xFFB300` → the colour, so an Android hex can be pasted as written.
    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(UIColor(hex: hex, alpha: alpha))
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
