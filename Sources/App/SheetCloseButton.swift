import SwiftUI

/// The one close control for every sheet and page that closes: the app's
/// accent cross.
///
/// **Where it sits decides its bubble.** In a navigation bar, iOS 26 already
/// puts every bar button in glass, so this adds nothing — wrapping it again drew
/// a ring inside a ring, and an interactive glass on a plain button flashed a
/// white square when pressed. Outside a bar (Settings' own header, the cast
/// page) there is no system bubble, so it uses iOS 26's glass button style,
/// whose pressed state is the system's; before iOS 26, a material circle.
struct SheetCloseButton: View {
    enum Placement {
        /// Inside a `ToolbarItem`.
        case toolbar
        /// Drawn in a screen's own header.
        case standalone
    }

    let placement: Placement
    let action: () -> Void

    init(_ placement: Placement = .toolbar, action: @escaping () -> Void) {
        self.placement = placement
        self.action = action
    }

    var body: some View {
        switch placement {
        case .toolbar:
            Button(action: action) {
                Image(systemName: "xmark")
                    .foregroundStyle(PanuraTheme.accent)
            }
            .accessibilityLabel("Close")
        case .standalone:
            standalone
        }
    }

    @ViewBuilder
    private var standalone: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) { glyph }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
        } else {
            Button(action: action) {
                glyph
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var glyph: some View {
        Image(systemName: "xmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PanuraTheme.accent)
    }
}
