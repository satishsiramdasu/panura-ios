import SwiftUI

/// The app's palette, ported value for value from Android's
/// `core/ui/theme/Color.kt` — amber on near-black in the dark scheme, amber-brown
/// on warm paper in the light one.
///
/// iOS had a purple accent of its own, which made the two apps look like
/// different products; every colour here is now the same hex Android ships.
///
/// Each token is a dynamic colour built from the light/dark pair, so a view
/// names `PanuraTheme.surfaceContainer` once and gets the right value in either
/// appearance. Material's own names are kept — `surfaceContainer`,
/// `onSurfaceVariant`, `secondaryContainer` — because the Android side is the
/// reference and a renamed token is one more thing to translate when comparing
/// the two screens.
enum PanuraTheme {
    // MARK: brand

    /// Amber 700. The accent everything selected, active or tappable wears.
    static let accent = dynamic(light: 0x7A5100, dark: 0xFFB300)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x3D2000)
    static let accentContainer = dynamic(light: 0xFFDEA3, dark: 0x5A3800)
    static let onAccentContainer = dynamic(light: 0x280E00, dark: 0xFFDEA3)

    /// The selected-pill fill: Material's `secondaryContainer`, which is what
    /// Android's bar, chips and menu cells use to mark "here".
    static let accentSoft = dynamic(light: 0xFBDDB6, dark: 0x553D00)
    static let onAccentSoft = dynamic(light: 0x281601, dark: 0xFBD891)

    // MARK: surfaces

    static let background = dynamic(light: 0xFFF8F0, dark: 0x0F0F0E)
    static let onBackground = dynamic(light: 0x1E1500, dark: 0xFFFFFF)
    static let surface = background
    static let onSurface = onBackground
    /// Inputs and inert wells — the address pill's fill.
    static let surfaceVariant = dynamic(light: 0xEEE0CC, dark: 0x1C1C1A)
    /// Secondary text. Android's dark value is white at 60%, not a grey.
    static let onSurfaceVariant = dynamic(
        light: 0x4E4030, dark: 0xFFFFFF, darkAlpha: 0.6
    )
    /// Bars and panels: the header, the bottom bar, the found bar, the menus.
    static let surfaceContainer = dynamic(light: 0xFFEDD8, dark: 0x181817)
    static let surfaceContainerHigh = dynamic(light: 0xF5E4CC, dark: 0x1E1E1D)
    static let surfaceContainerHighest = dynamic(light: 0xECDCC4, dark: 0x252524)
    static let outline = dynamic(light: 0x80705C, dark: 0x706050)
    static let outlineVariant = dynamic(light: 0xD2C4B0, dark: 0x3A3020)

    // MARK: status

    static let error = dynamic(light: 0xDC5050, dark: 0xFF8A80)
    /// Sizes, durations — anything that is information rather than a verdict.
    /// Material's tertiary, so it reads as distinct from the accent beside it.
    static let tertiary = dynamic(light: 0x6B5C3E, dark: 0xCCBE90)
    /// A probe that came back alive.
    static let success = dynamic(light: 0x2E7D32, dark: 0x81C784)

    // MARK: incognito

    /// Android repaints the browser violet in private mode. iOS tints the pill
    /// and the menu's private row with the same values rather than swapping a
    /// whole scheme — the browser is one screen here, not a nav graph.
    static let incognito = Color(hex: 0xC7A9FF)
    static let incognitoContainer = Color(hex: 0x3B1F7A)
    static let incognitoSurface = Color(hex: 0x241F30)

    // MARK: shape

    static let cornerLarge: CGFloat = 28
    static let cornerMedium: CGFloat = 16

    // MARK: plumbing

    /// One token, both appearances. `UIColor`'s trait-aware initialiser is what
    /// makes this work without an asset catalog or an environment read at every
    /// call site.
    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension Color {
    /// `0xFFB300` → the colour, so the Android hex can be pasted as written.
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
