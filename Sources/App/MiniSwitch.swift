import SwiftUI

/// A switch drawn small enough to sit under a label.
///
/// Not a `Toggle`. A system toggle is 51 points wide with a fixed shape, and
/// scaling one down distorts its stroke and its shadow and still answers taps
/// on its own — which is wrong here, because the whole tile is the button and
/// the switch is only the part that shows the state. This draws the state and
/// nothing else: no gesture, no hit testing, no opinion about the colour it is
/// told to use.
struct MiniSwitch: View {
    let on: Bool
    let tint: Color

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? tint.opacity(0.35) : PanuraTheme.surfaceContainerHighest)
            Circle()
                .fill(on ? tint : PanuraTheme.onSurfaceVariant)
                .frame(width: 12, height: 12)
                .padding(2)
        }
        .frame(width: 30, height: 16)
        .animation(.easeOut(duration: 0.18), value: on)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
