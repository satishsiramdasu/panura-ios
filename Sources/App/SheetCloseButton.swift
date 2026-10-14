import SwiftUI

/// The one close control for every sheet and page that closes: a plain cross
/// in the accent colour, as Help, Report and Settings have always worn it.
///
/// Tried as the system's own close button — iOS 26's glass circle, UIKit's
/// grey one before it — and it read as foreign next to the app's other bar
/// glyphs, so it is back to this.
struct SheetCloseButton: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
