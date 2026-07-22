import SwiftUI

/// Edge-drag back/forward navigation — the SwiftUI port of Android's
/// `BrowserGestureNav`. Dragging in from either edge rubber-bands a circular
/// indicator that follows your finger vertically; crossing the threshold fires
/// a haptic and confirms the navigation on release, otherwise it springs back.
///
/// Kept deliberately narrow (20pt strips) with a claim threshold so ordinary
/// taps and page scrolling still reach the web view underneath.
struct BrowserGestureNav: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void

    private let edgeZone: CGFloat = 20
    private let indicator: CGFloat = 52
    private let maxDrag: CGFloat = 120
    private let trigger: CGFloat = 70

    @State private var leftDrag: CGFloat = 0
    @State private var leftTouchY: CGFloat = 0
    @State private var leftActive = false
    @State private var leftCrossed = false

    @State private var rightDrag: CGFloat = 0
    @State private var rightTouchY: CGFloat = 0
    @State private var rightActive = false
    @State private var rightCrossed = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if canGoBack { leftEdge }
                if canGoForward { rightEdge(width: geo.size.width) }

                if leftActive {
                    indicatorView(
                        systemName: "chevron.left",
                        drag: leftDrag,
                        crossed: leftCrossed,
                        x: leftDrag - indicator / 2,
                        y: leftTouchY - indicator / 2
                    )
                }
                if rightActive {
                    indicatorView(
                        systemName: "chevron.right",
                        drag: rightDrag,
                        crossed: rightCrossed,
                        x: geo.size.width - rightDrag - indicator / 2,
                        y: rightTouchY - indicator / 2
                    )
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: edges

    private var leftEdge: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: edgeZone)
            .frame(maxHeight: .infinity, alignment: .leading)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        leftTouchY = value.startLocation.y
                        leftDrag = rubberBand(value.translation.width)
                        leftActive = leftDrag > 0
                        updateCrossed(leftDrag, was: &leftCrossed)
                    }
                    .onEnded { _ in
                        finish(drag: leftDrag, action: onBack) {
                            leftDrag = 0; leftActive = false; leftCrossed = false
                        }
                    }
            )
    }

    private func rightEdge(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: edgeZone)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        rightTouchY = value.startLocation.y
                        rightDrag = rubberBand(-value.translation.width)
                        rightActive = rightDrag > 0
                        updateCrossed(rightDrag, was: &rightCrossed)
                    }
                    .onEnded { _ in
                        finish(drag: rightDrag, action: onForward) {
                            rightDrag = 0; rightActive = false; rightCrossed = false
                        }
                    }
            )
    }

    // MARK: indicator

    private func indicatorView(
        systemName: String, drag: CGFloat, crossed: Bool, x: CGFloat, y: CGFloat
    ) -> some View {
        let progress = min(max(drag / maxDrag, 0), 1)
        return Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(crossed ? Color.white : Color.primary)
            .frame(width: indicator, height: indicator)
            .background(crossed ? PanuraTheme.accent : Color(.secondarySystemBackground),
                        in: Circle())
            .shadow(radius: 6)
            .scaleEffect(0.5 + 0.5 * progress)
            .opacity(Double(min(progress / 0.25, 1)))
            .offset(x: x, y: y)
            .allowsHitTesting(false)
    }

    // MARK: helpers

    /// Linear up to `maxDrag`, then 15% for the overshoot — same feel as Android.
    private func rubberBand(_ raw: CGFloat) -> CGFloat {
        guard raw > 0 else { return 0 }
        return raw <= maxDrag ? raw : maxDrag + (raw - maxDrag) * 0.15
    }

    private func updateCrossed(_ drag: CGFloat, was crossed: inout Bool) {
        let nowCrossed = drag >= trigger
        if nowCrossed && !crossed {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        crossed = nowCrossed
    }

    private func finish(drag: CGFloat, action: () -> Void, reset: () -> Void) {
        if drag >= trigger {
            reset()
            action()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { reset() }
        }
    }
}
