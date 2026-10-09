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

    /// How far the tab tops are rounded. Matched to nothing else on purpose —
    /// it is the one shape in the app that has to read as a physical tab.
    private let corner: CGFloat = 14
    private let gutter: CGFloat = 8
    private let gap: CGFloat = 4

    private var showsMore: Bool { !more.isEmpty || !planned.isEmpty }
    private var moreActive: Bool {
        more.contains(selection) || planned.contains(selection)
    }
    var body: some View {
        GeometryReader { geo in
            let width = seatWidth(in: geo.size.width)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(tabs, id: \.self) { tab in
                        tabButton(tab, width: width)
                    }
                    if showsMore { moreButton(width: width) }
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

    private func tabButton(_ tab: AppDestination, width: CGFloat) -> some View {
        seat(
            icon: tab.icon(selected: selection == tab),
            label: shortTitle(tab),
            active: selection == tab,
            fill: tab.chrome,
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
                fill: selection.chrome,
                width: width
            )
        }
        .menuOrder(.fixed)
        .accessibilityLabel("More")
    }

    /// One tab, selected or not. Shared so the `More` menu's label cannot drift
    /// out of step with the tabs beside it.
    private func seat(
        icon: String,
        label: String,
        active: Bool,
        fill: Color,
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
        .frame(height: Self.height - 4, alignment: .center)
        // Rounded on top only. Rounded at the bottom too and it would be a pill
        // sitting above the panel; this one has to join it.
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: corner,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: corner,
                style: .continuous
            )
            // An unselected tab sits between the two: lighter than the
            // ground so it reads as a tab, darker than the selected one so it
            // reads as behind it.
            .fill(active ? fill : PanuraTheme.surfaceContainerHigh.opacity(0.55))
        )
        .contentShape(Rectangle())
    }

    /// "Network Stream" is the label from when it had a whole drawer row. A
    /// seat has about seven characters.
    private func shortTitle(_ tab: AppDestination) -> String {
        tab == .stream ? "Network" : tab.title
    }
}
