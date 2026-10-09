import SwiftUI

/// The app's navigation: a row of notched tabs under the header.
///
///     ╭────────╮╭────────╮╭────────╮╭────╮
///     │ Browser││ Videos ││Network ││ +  │
///     ┕━━━━━━━━┙└────────┘└────────┘└────┘
///
/// The selected tab is painted in the *content's* colour and keeps its bottom
/// edge open, so it reads as the front of the panel below rather than as a
/// button that happens to be lit. The unselected ones sit back in the header's
/// colour. That is the whole trick, and it is why this is drawn by hand instead
/// of being a `Picker`: the join between the tab and what it opens is the
/// thing doing the explaining.
///
/// The trailing `+` is not a destination. It is a menu of the places that do
/// not have a seat yet — see `FeatureFlags.showsPlannedTabs`.
struct ShellTabBar: View {
    let tabs: [AppDestination]
    @Binding var selection: AppDestination
    /// Destinations behind the `+`. Empty hides the button entirely.
    var planned: [AppDestination] = []
    /// One of them is the screen you are on, so the `+` is drawn as the front
    /// of the panel like any other selected tab. Without this the strip would
    /// show nothing selected while you were standing in one of them.
    var plannedActive: Bool = false
    var onSelectPlanned: (AppDestination) -> Void = { _ in }

    /// How far the tab tops are rounded. Matched to nothing else on purpose —
    /// it is the one shape in the app that has to read as a physical tab.
    private let corner: CGFloat = 14

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                tabButton(tab)
            }
            if !planned.isEmpty { plusButton }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .background(PanuraTheme.surfaceContainer)
    }

    private func tabButton(_ tab: AppDestination) -> some View {
        let active = selection == tab
        return Button {
            guard !active else { return }
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon(selected: active))
                    .font(.system(size: 17, weight: active ? .semibold : .regular))
                Text(shortTitle(tab))
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? PanuraTheme.onSurface : PanuraTheme.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // Rounded on top only. A tab rounded at the bottom too would be a
            // pill sitting above the panel; this one has to join it.
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: corner,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: corner,
                    style: .continuous
                )
                .fill(active ? PanuraTheme.background : PanuraTheme.surfaceContainerHigh)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// "Network Stream" is the drawer's label, written when it had a whole row
    /// to itself. A tab has about seven characters.
    private func shortTitle(_ tab: AppDestination) -> String {
        tab == .stream ? "Network" : tab.title
    }

    private var plusButton: some View {
        Menu {
            Section("Not built yet") {
                ForEach(planned, id: \.self) { tab in
                    Button {
                        onSelectPlanned(tab)
                    } label: {
                        Label(tab.title, systemImage: tab.icon(selected: false))
                    }
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                Text("More")
                    .font(.system(size: 11, weight: plannedActive ? .semibold : .regular))
            }
            .foregroundStyle(plannedActive ? PanuraTheme.onSurface : PanuraTheme.onSurfaceVariant)
            .frame(width: 52)
            .padding(.vertical, 8)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: corner,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: corner,
                    style: .continuous
                )
                .fill(plannedActive ? PanuraTheme.background : PanuraTheme.surfaceContainerHigh)
            )
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("More")
    }
}
