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

    private var standalone: some View {
        GlassCircleButton(systemImage: "xmark", label: "Close", action: action)
    }
}

/// An accent glyph in a round glass button, for a screen's own header — the
/// close cross and Settings' back chevron share it so the pair matches.
struct GlassCircleButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            // Drawn to the exact 44-point bubble iOS gives a bar button, which
            // is what the Library and Help sheets show. Not `.glass`: that
            // style pads around its label, so a 44-point label became a
            // bubble far bigger than the bar's. Not interactive glass either,
            // which flashes a white square on press; the press is a dip.
            Button(action: action) {
                glyph
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressDip())
            .accessibilityLabel(label)
        } else {
            Button(action: action) {
                glyph
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

    private var glyph: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(PanuraTheme.accent)
    }
}

/// A slight shrink and fade while held — the feedback a bar button gives.
private struct PressDip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
