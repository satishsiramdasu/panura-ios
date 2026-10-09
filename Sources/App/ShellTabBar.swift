import SwiftUI

/// The app's navigation: a row of notched tabs under the header.
///
///     ╭────────╮╭────────╮╭────────╮╭────────╮
///     │  Home  ││Browser ││ Videos ││  More  │
///     ┕━━━━━━━━┙└────────┘└────────┘└────────┘
///
/// The selected tab is painted in its own destination's colour and keeps its
/// bottom edge open, so it reads as the front of the panel below rather than as
/// a button that happens to be lit. The unselected ones sit back on the bar's
/// darker ground. That join is the whole trick, and it is why this is drawn by
/// hand instead of being a `Picker` or a `UITabBar`: neither can make a tab
/// continuous with what it opens.
///
/// **Four across, always.** Each seat is a fixed quarter of the width, so a
/// fifth does not shrink the other four — it peeks over the right edge, which
/// is the only honest way to say there is more without making what is already
/// there worse.
///
/// The trailing `More` is a menu, not a destination of its own: the places that
/// do not earn a seat live behind it, and it lights up like any other tab while
/// you are standing in one of them.
struct ShellTabBar: View {
    let tabs: [AppDestination]
    @Binding var selection: AppDestination
    /// Behind `More`, and real — Network Stream is a working screen that simply
    /// is not worth a quarter of the row.
    var more: [AppDestination] = []
    /// Behind `More`, under their own heading, and not built. Empty in a build
    /// with `FeatureFlags.showsPlannedTabs` off.
    var planned: [AppDestination] = []
    var onSelect: (AppDestination) -> Void = { _ in }
    /// The ground the tabs are cut out of: the selected tab's deep tone.
    var ground: Color = AppChrome.bar
    /// Private browsing, which repaints the Browser tab violet rather than
    /// amber. Passed in rather than read from `BrowserSession` here, so the
    /// strip stays a function of what it is handed.
    var privateBrowsing: Bool = false

    /// How far the tab tops are rounded. Matched to nothing else on purpose —
    /// it is the one shape in the app that has to read as a physical tab.
    private let corner: CGFloat = 14
    private let gutter: CGFloat = 8
    /// Negative: the tabs overlap. A gap between them makes four separate
    /// buttons; tucking each one behind its neighbour makes a stack of pages,
    /// which is the whole idea — the selected one is the page in front and the
    /// rest are filed behind it. The overlap is small enough that no label
    /// loses a letter at 375pt, where a seat is still about 90 points wide.
    private let gap: CGFloat = -8

    private var showsMore: Bool { !more.isEmpty || !planned.isEmpty }
    private var moreActive: Bool {
        more.contains(selection) || planned.contains(selection)
    }
    var body: some View {
        GeometryReader { geo in
            let width = seatWidth(in: geo.size.width)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                        tabButton(tab, at: index, width: width)
                            .zIndex(stacking(at: index))
                    }
                    if showsMore {
                        moreButton(width: width)
                            .zIndex(stacking(at: tabs.count))
                    }
                }
                .padding(.horizontal, gutter)
            }
            // The row scrolls; the ground under it does not, or the darker bar
            // would slide out from behind the tabs with them.
            .background(ground)
        }
        .frame(height: Self.height)
    }

    /// Glyph, label and the padding around them. Fixed, because the row is
    /// measured in whole seats and a seat that resizes with its content would
    /// make "Browser" and "Home" different widths.
    static let height: CGFloat = 54

    /// A quarter of what is left after the gutters and the gaps between four
    /// seats — never a share of the actual count, which is what keeps a fifth
    /// peeking instead of squeezing.
    private func seatWidth(in total: CGFloat) -> CGFloat {
        let perRow = AppChrome.tabsPerRow
        let usable = total - gutter * 2 - gap * (perRow - 1)
        return max(64, usable / perRow)
    }

    private func tabButton(_ tab: AppDestination, at index: Int, width: CGFloat) -> some View {
        seat(
            icon: tab.icon(selected: selection == tab),
            label: shortTitle(tab),
            active: selection == tab,
            fill: selection == tab
                ? AnyShapeStyle(tab.chrome(privateBrowsing: privateBrowsing))
                : AnyShapeStyle(leaning(from: index)),
            at: index,
            width: width
        )
        .onTapGesture {
            guard selection != tab else { return }
            onSelect(tab)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
    }

    private func moreButton(width: CGFloat) -> some View {
        Menu {
            ForEach(more, id: \.self) { tab in
                Button { onSelect(tab) } label: {
                    Label(tab.title, systemImage: tab.icon(selected: false))
                }
            }
            if !planned.isEmpty {
                Section("Not built yet") {
                    ForEach(planned, id: \.self) { tab in
                        Button { onSelect(tab) } label: {
                            Label(tab.title, systemImage: tab.icon(selected: false))
                        }
                    }
                }
            }
        } label: {
            seat(
                icon: "square.grid.2x2",
                label: "More",
                active: moreActive,
                fill: moreActive
                    ? AnyShapeStyle(selection.chrome(privateBrowsing: privateBrowsing))
                    : AnyShapeStyle(leaning(from: tabs.count)),
                at: tabs.count,
                width: width
            )
        }
        .menuOrder(.fixed)
        .accessibilityLabel("More")
    }

    /// Where the selected seat is sitting, counting `More` as the last one.
    ///
    /// nil is impossible in practice - something is always selected - but a
    /// destination reached by deep link that has no seat would land here, and a
    /// row of tabs all leaning nowhere is the right answer for it.
    private var activeIndex: Int? {
        if let i = tabs.firstIndex(of: selection) { return i }
        return moreActive ? tabs.count : nil
    }

    /// Who is in front of whom.
    ///
    /// The selected tab is the page on top; every other one is filed further
    /// back the further it is from the selected one, so the overlaps all run
    /// toward where you are standing instead of all running left to right.
    /// Without this the row is still a stack, but one whose order has nothing
    /// to do with anything.
    private func stacking(at index: Int) -> Double {
        guard let active = activeIndex else { return 0 }
        return active == index ? 100 : -Double(abs(active - index))
    }

    /// An unselected tab, shaded toward the selected one.
    ///
    /// Each one is brightest on the edge facing where you are and falls away
    /// from it, so the row has a direction: the strip reads as a run of panels
    /// behind the open one, lit by it, rather than as four buttons of which one
    /// happens to be on. It also means the tab next to the selected one is the
    /// lightest unselected tab on screen, which is true - it is the nearest.
    ///
    /// Deliberately faint. The first pass ran this ramp nearly to full strength
    /// and it read as exactly what it is, a gradient painted on a button - the
    /// shading is not what says "page". The edge is.
    private func leaning(from index: Int) -> LinearGradient {
        let far = PanuraTheme.surfaceContainerHigh.opacity(0.20)
        // The open panel's own colour, weak. Borrowing the hue rather than
        // lightening neutrally is what points at it; a grey ramp would only
        // look like a gradient.
        let near = selection.chrome(privateBrowsing: privateBrowsing).opacity(0.55)
        guard let active = activeIndex, active != index else {
            return LinearGradient(colors: [far, far], startPoint: .leading, endPoint: .trailing)
        }
        let activeIsRight = active > index
        return LinearGradient(
            colors: [far, near],
            startPoint: activeIsRight ? .leading : .trailing,
            endPoint: activeIsRight ? .trailing : .leading
        )
    }

    /// The lit edge that makes a tab a sheet of paper.
    ///
    /// This is the piece that was missing. A tab is a rectangle of a slightly
    /// different colour, and nothing about a colour says it has a thickness or
    /// that something is behind it — a lifted edge does, which is why every
    /// physical-looking tab strip has one. With the tabs overlapping, each
    /// edge also lands on top of its neighbour, which is what turns four
    /// shapes into a stack.
    ///
    /// Brightest at the top and gone by the bottom, for a plain reason: the
    /// bottom of this shape is the join with the bar underneath, and a hairline
    /// drawn across it would be a seam in the one place the whole design is
    /// trying not to have one.
    ///
    /// **And gone on whichever side is tucked underneath.** A tab is overlapped
    /// by whichever neighbour is nearer the selected one, so one of its two
    /// sides is behind another tab - but the corner radius is larger than the
    /// overlap, so a border drawn all the way round came creeping out from
    /// behind the tab in front as a stray lit curve. An edge you can see on a
    /// side that is underneath something is exactly the thing that tells you it
    /// is not really underneath it. So the lit side is the exposed one, and the
    /// gradient runs diagonally from that top corner to nothing well before it
    /// reaches the covered one.
    private func edge(active: Bool, at index: Int) -> LinearGradient {
        let lit = Color.white.opacity(active ? 0.10 : 0.16)
        // The selected tab is in front of everything; both its sides show.
        guard !active, let selected = activeIndex, selected != index else {
            return LinearGradient(colors: [lit, .clear], startPoint: .top, endPoint: .bottom)
        }
        // The neighbour nearer the selected tab is the one on top of this, so
        // the side facing the selection is the covered one.
        let selectionIsRight = selected > index
        return LinearGradient(
            stops: [.init(color: lit, location: 0), .init(color: .clear, location: 0.55)],
            startPoint: selectionIsRight ? .topLeading : .topTrailing,
            endPoint: selectionIsRight ? .bottomTrailing : .bottomLeading
        )
    }

    /// One tab, selected or not. Shared so the `More` menu's label cannot drift
    /// out of step with the tabs beside it.
    private func seat(
        icon: String,
        label: String,
        active: Bool,
        fill: AnyShapeStyle,
        at index: Int,
        width: CGFloat
    ) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: active ? .semibold : .regular))
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(active ? PanuraTheme.onSurface : PanuraTheme.onSurfaceVariant)
        .frame(width: width)
        .padding(.vertical, 8)
        // The full height of the strip, with nothing under it. It used to be
        // `height - 4`, and a horizontal `ScrollView` pins its content to the
        // top - so those four points became a band of the strip's near-black
        // ground between the selected tab and the bar it is supposed to join,
        // which is the one thing this shape exists to avoid.
        .frame(height: Self.height, alignment: .center)
        // Rounded on top only. Rounded at the bottom too and it would be a pill
        // sitting above the panel; this one has to join it.
        .background(
            ZStack {
                // Opaque first. An unselected tab's fill is a translucent ramp,
                // and now that the tabs overlap, translucency would let the one
                // behind show through the one in front - which is the opposite
                // of a stack.
                seatShape.fill(ground)
                // Both cases arrive resolved: the destination's own colour when
                // this is where you are, and a ramp toward it when it is not.
                seatShape.fill(fill)
                seatShape.strokeBorder(edge(active: active, at: index), lineWidth: 1)
            }
        )
        .contentShape(Rectangle())
    }

    private var seatShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: corner,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: corner,
            style: .continuous
        )
    }

    /// "Network Stream" is the label from when it had a whole drawer row. A
    /// seat has about seven characters.
    private func shortTitle(_ tab: AppDestination) -> String {
        tab == .stream ? "Network" : tab.title
    }
}
