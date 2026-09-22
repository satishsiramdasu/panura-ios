import SwiftUI

/// A panel that hangs below the header, pointing at the button that opened it.
///
/// This was a `.popover` for one round, which is the right idea and the wrong
/// mechanism on a phone: `presentationCompactAdaptation(.popover)` hands the
/// placement to UIKit, and UIKit put the site panel *over* the address bar it
/// was supposed to hang under, and the cast panel off the side of the screen
/// entirely. There is nothing to configure — the geometry is UIKit's to decide.
///
/// So the geometry is ours again, and the only thing the popover was really
/// buying — the arrow that ties the panel to its button — is drawn here. It is
/// a fixed position under a fixed button: the header is 52 points tall and the
/// two buttons it can belong to are at known offsets, so there is nothing to
/// measure and nothing to get wrong.
/// Which end of the header the button sits at.
///
/// Its own type rather than nested inside the generic panel: written there,
/// every caller has to name the panel's content type before it can say
/// `.leading`.
enum PanelSide {
    case leading, trailing

    var alignment: Alignment { self == .leading ? .topLeading : .topTrailing }
    var edge: Edge.Set { self == .leading ? .leading : .trailing }
    var unitPoint: UnitPoint { self == .leading ? .topLeading : .topTrailing }
}

struct AnchoredPanel<Content: View>: View {
    let side: PanelSide
    /// From the panel's own edge to the middle of the button it points at.
    var pointerInset: CGFloat = 62
    var width: CGFloat = PanelMetrics.width
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            pointer
            content
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: PanelMetrics.corner, style: .continuous)
                        .fill(PanelMetrics.surface)
                )
        }
        .frame(width: width)
        .shadow(color: .black.opacity(0.42), radius: 20, y: 8)
    }

    /// Kept clear of the rounded corners: an arrow growing out of a curve reads
    /// as a drawing mistake rather than as a pointer.
    private var pointer: some View {
        let inset = max(pointerInset, PanelMetrics.corner + 6)
        return HStack(spacing: 0) {
            if side == .trailing { Spacer(minLength: 0) }
            PointerShape()
                .fill(PanelMetrics.surface)
                .frame(width: 22, height: 10)
                .padding(side.edge, inset - 11)
            if side == .leading { Spacer(minLength: 0) }
        }
    }
}

/// One set of numbers for both panels, so they cannot drift apart.
enum PanelMetrics {
    /// Wide enough for a device name or a site's controls, never the width of
    /// the screen: a panel that spans the screen reads as a new screen.
    static var width: CGFloat { min(UIScreen.main.bounds.width * 0.82, 360) }
    static let corner: CGFloat = 16
    /// A step lighter than the header it hangs from — that difference is what
    /// separates the two without a line between them.
    static var surface: Color { PanuraTheme.surfaceContainerHigh }
    /// Header, then a hair of daylight, so the arrow has somewhere to be.
    static var topOffset: CGFloat { PanuraHeader<AnyView>.height + 2 }
    /// The middle of the Panura mark, from the left edge of the screen: 6 points
    /// of bar padding, the 38-point menu button, the HStack's 4, then half of a
    /// 44-point button.
    static let glyphCentre: CGFloat = 70
    /// The middle of the cast mark, from the right edge.
    static let castCentre: CGFloat = 28
    /// What the panel keeps between itself and the side of the screen.
    static let margin: CGFloat = 8

    static var motion: Animation { .spring(response: 0.3, dampingFraction: 0.82) }

    /// The found-video sheet's poster. Wide, because it is the one picture in
    /// that sheet and it is what makes it recognisable at a glance.
    static var posterWidth: CGFloat { min(UIScreen.main.bounds.width - 72, 320) }
}

/// The arrow. A triangle with its tip rounded off, because a needle-sharp point
/// looks broken at this size on a retina screen.
private struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.35)
        )
        path.closeSubpath()
        return path
    }
}

/// Everything a panel needs around it: the header kept live but inert, a scrim
/// over the rest, and the panel itself growing out of its button.
///
/// Written once because the two panels must behave identically — they are the
/// same object opened from opposite ends of the same bar.
struct PanelScaffold<Content: View>: View {
    let side: PanelSide
    let onDismiss: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            // The header keeps its colour — the button that opened this is in
            // it — but nothing in it fires while the panel is open. The bar
            // holds the address, back, forward and the cast mark, and any of
            // them going off under an open panel is an accident.
            Color.black.opacity(0.001)
                .frame(height: PanuraHeader<AnyView>.height)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            ZStack(alignment: side.alignment) {
                Color.black.opacity(0.32)
                    .ignoresSafeArea(edges: .bottom)
                    .onTapGesture(perform: onDismiss)

                AnchoredPanel(
                    side: side,
                    pointerInset: side == .leading
                        ? PanelMetrics.glyphCentre - PanelMetrics.margin
                        : PanelMetrics.castCentre - PanelMetrics.margin
                ) {
                    content
                }
                .padding(side.edge, PanelMetrics.margin)
                .padding(.top, 2)
                // Out of the button, not out of the corner of the screen.
                .transition(
                    .scale(scale: 0.86, anchor: side.unitPoint).combined(with: .opacity)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - which destination is on screen

/// True while the destination this view belongs to is the one being shown.
///
/// All five are composed at once and hidden with opacity, so five copies of the
/// header exist at every moment. Anything a header presents has to know whether
/// it is the one being looked at.
private struct DestinationActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var destinationIsActive: Bool {
        get { self[DestinationActiveKey.self] }
        set { self[DestinationActiveKey.self] = newValue }
    }
}
