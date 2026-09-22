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

    /// The arrow is part of the panel, not a triangle stacked on top of one.
    ///
    /// Two shapes cannot be made to blend: they meet on a seam that survives
    /// anti-aliasing, and a shadow drawn round the pair traces that seam as a
    /// dark line straight through the join. One path has no join to trace.
    var body: some View {
        content
            .frame(width: width)
            .padding(.top, PanelMetrics.pointerHeight)
            .background(
                PanelBubble(
                    corner: PanelMetrics.corner,
                    pointerInset: max(
                        pointerInset,
                        PanelMetrics.corner + PanelMetrics.pointerWidth / 2
                    ),
                    pointerWidth: PanelMetrics.pointerWidth,
                    pointerHeight: PanelMetrics.pointerHeight,
                    side: side
                )
                .fill(PanelMetrics.surface)
            )
            // Flattens panel and arrow into one silhouette before the shadow is
            // drawn, so the shadow goes round the outside instead of round each
            // piece.
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
    }
}

/// One set of numbers for both panels, so they cannot drift apart.
enum PanelMetrics {
    /// Wide enough for a device name or a site's controls, never the width of
    /// the screen: a panel that spans the screen reads as a new screen.
    static var width: CGFloat { min(UIScreen.main.bounds.width * 0.82, 360) }
    static let corner: CGFloat = 14
    static let pointerWidth: CGFloat = 22
    static let pointerHeight: CGFloat = 9
    /// A step lighter than the header it hangs from — that difference is what
    /// separates the two without a line between them.
    static var surface: Color { PanuraTheme.surfaceContainerHigh }
    /// Header, then a hair of daylight, so the arrow has somewhere to be.
    static var topOffset: CGFloat { PanuraHeader<AnyView>.height + 2 }
    /// The middle of the Panura mark, from the left edge of the screen.
    ///
    /// The mark moved inside the address pill, so the sum gained a term: bar
    /// padding, the 38-point menu button, the bar's spacing, the pill's own 6
    /// points of padding, then half of a 44-point button. Computed rather than
    /// written down, because two of those terms are smaller on a 375pt phone
    /// and an arrow three points off its button is visible.
    static var glyphCentre: CGFloat {
        AppChrome.headerPadding + 38 + AppChrome.headerSpacing + 6 + 22
    }
    /// The middle of the cast mark, from the right edge.
    static let castCentre: CGFloat = 28
    /// What the panel keeps between itself and the side of the screen. Small,
    /// because the arrow has to reach a button that is itself near the edge.
    static let margin: CGFloat = 6

    static var motion: Animation { .spring(response: 0.3, dampingFraction: 0.82) }

    /// The found-video sheet's poster. Wide, because it is the one picture in
    /// that sheet and it is what makes it recognisable at a glance.
    static var posterWidth: CGFloat { min(UIScreen.main.bounds.width - 72, 320) }
}

/// The panel and its arrow as one outline.
///
/// The arrow is a triangle with straight edges — it was a quadratic curve once,
/// which makes a dome, the shape of a speech bubble's tail rather than of
/// something indicating a button. Its base is pulled half a point into the card
/// so the two parts of the path overlap rather than abut; a path that merely
/// touches itself still shows the join.
private struct PanelBubble: Shape {
    let corner: CGFloat
    /// From the panel's own edge to the middle of the arrow.
    let pointerInset: CGFloat
    let pointerWidth: CGFloat
    let pointerHeight: CGFloat
    let side: PanelSide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = CGRect(
            x: rect.minX, y: rect.minY + pointerHeight,
            width: rect.width, height: max(0, rect.height - pointerHeight)
        )
        path.addRoundedRect(
            in: body,
            cornerSize: CGSize(width: corner, height: corner),
            style: .continuous
        )

        let centre = side == .leading
            ? rect.minX + pointerInset
            : rect.maxX - pointerInset
        let half = pointerWidth / 2
        path.move(to: CGPoint(x: centre - half, y: body.minY + 0.5))
        path.addLine(to: CGPoint(x: centre, y: rect.minY))
        path.addLine(to: CGPoint(x: centre + half, y: body.minY + 0.5))
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
                // Up into the bar by a few points, so the arrow reaches its
                // button instead of pointing at it from across a gap. The bar
                // is 52 tall and its buttons are 44, so there is dead space at
                // the bottom of it for the arrow to claim.
                .padding(.top, -5)
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
