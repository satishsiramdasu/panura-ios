import SwiftUI

/// The one close control for every sheet and page that closes: the app's
/// accent cross, sitting in a bubble.
///
/// The system's own close button was tried and read as foreign next to the
/// app's other bar glyphs, so the cross stays ours. The bubble is iOS 26's
/// glass, which also answers the touch; before iOS 26, a material circle in
/// the same place.
struct SheetCloseButton: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(Bubble())
        .accessibilityLabel("Close")
    }
}

private struct Bubble: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}
