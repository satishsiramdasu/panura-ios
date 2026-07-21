import SwiftUI

/// Central palette. Mirrors the Android purple accent brand.
enum PanuraTheme {
    static let accent = Color(red: 0.45, green: 0.30, blue: 0.90)   // brand purple
    static let accentSoft = Color(red: 0.45, green: 0.30, blue: 0.90).opacity(0.14)

    static let cornerLarge: CGFloat = 28
    static let cornerMedium: CGFloat = 16
}
