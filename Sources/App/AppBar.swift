import SwiftUI

/// Where you can be. Home, Web and Videos have a seat in the bar; Stream and
/// Settings live behind the grid, because they are places you visit
/// occasionally rather than switch between.
enum AppDestination: Hashable, CaseIterable {
    case home, web, videos, stream, settings

    var title: String {
        switch self {
        // "Web", not "Browser": the app is sold as a web video player, so the
        // seat says the same word the listing does.
        case .home: return "Home"
        case .web: return "Web"
        case .videos: return "Videos"
        case .stream: return "Network Stream"
        case .settings: return "Settings"
        }
    }

    /// Short enough for a bar pill — "Network Stream" does not fit one.
    var barTitle: String {
        self == .stream ? "Stream" : title
    }

    func icon(selected: Bool) -> String {
        switch self {
        case .home: return selected ? "house.fill" : "house"
        case .web: return selected ? "globe.americas.fill" : "globe"
        case .videos: return selected ? "film.fill" : "film"
        case .stream: return "link"
        case .settings: return selected ? "gearshape.fill" : "gearshape"
        }
    }

    /// True for the two that have no seat of their own.
    var livesBehindGrid: Bool { self == .stream || self == .settings }
}

/// The app's one bottom bar.
///
/// Three zones rather than five evenly-spread slots: **Home pinned left**, the
/// **destination pair centred**, the **grid pinned right**. Home and the grid
/// are the app's two fixed points, so they hold the same pixel on every screen
/// and never move as the middle changes under them.
///
/// The current destination grows a pill with its name in it and the others stay
/// glyphs, so exactly one label is on screen and it is the one saying where you
/// are. The grid never labels itself — it is a control, not a place — but a
/// destination that lives behind it borrows a pill of its own, or nothing on
/// screen would say where you are.
///
/// It reserves its height rather than overlaying the page: a screen that does
/// not scroll can never scroll out from under an overlay, which would put the
/// bottom of those screens permanently out of reach.
struct AppBarRow: View {
    let selection: AppDestination
    let menuOpen: Bool
    let onSelect: (AppDestination) -> Void
    let onToggleMenu: () -> Void

    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            seat(.home)
            seat(.web)
            seat(.videos)
            // A grid destination gets a pill wearing its own icon rather than
            // borrowing the grid's: the grid is the way in and out of the panel
            // and has to stay recognisably itself. Tapping the pill reopens the
            // panel it came from, which is the only place its siblings live.
            if selection.livesBehindGrid {
                pill(
                    icon: selection.icon(selected: true),
                    label: selection.barTitle,
                    selected: true,
                    action: onToggleMenu
                )
            }
            // Never marked as a destination: it is a launcher, not a place.
            pill(
                icon: menuOpen ? "chevron.down" : "square.grid.2x2",
                label: nil,
                selected: menuOpen,
                action: onToggleMenu
            )
            .accessibilityLabel(menuOpen ? "Close menu" : "More")
            Spacer(minLength: 0)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(PanuraTheme.surfaceContainer)
    }

    private func seat(_ destination: AppDestination) -> some View {
        let selected = selection == destination
        return pill(
            icon: destination.icon(selected: selected),
            // Only the current seat is captioned — one label on screen, and it
            // is the one that says where you are.
            label: selected ? destination.barTitle : nil,
            selected: selected,
            action: { onSelect(destination) }
        )
        .accessibilityLabel(destination.title)
    }

    private func pill(
        icon: String,
        label: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: label == nil ? 19 : 16, weight: .medium))
                    // The fill fades in; without this the glyph inside it just
                    // sits there while that happens.
                    .scaleEffect(selected ? 1.1 : 1)
                if let label {
                    Text(label)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
            .frame(height: 38)
            .padding(.horizontal, label == nil ? 14 : 12)
            .background(
                Capsule().fill(selected ? PanuraTheme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// The app's global menu: section navigation for everything without a seat in
/// the bar.
///
/// A grid, not a list: this names app sections, while the browser's own menu —
/// in its address pill — names page actions, and the two should not look alike.
/// It has no close control of its own, because the bar's grid button turns into
/// the chevron that closes it.
struct AppMenuPanel: View {
    struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let action: () -> Void
    }

    let items: [Item]
    /// Highlighted because you are already there.
    let current: AppDestination?

    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { item in
                Button(action: item.action) {
                    VStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 20))
                            .frame(width: 46, height: 46)
                            .background(
                                Circle().fill(
                                    current?.title == item.label
                                        ? PanuraTheme.accentSoft
                                        : PanuraTheme.surfaceVariant
                                )
                            )
                            .foregroundStyle(
                                current?.title == item.label ? PanuraTheme.accent : Color.primary
                            )
                        Text(item.label)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(TopRoundedRectangle(radius: 20).fill(PanuraTheme.surfaceContainer))
    }
}

/// Rounded at the top only. `UnevenRoundedRectangle` would say this in one line
/// but is iOS 17, and the app ships to 16.
private struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: [.topLeft, .topRight],
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath
        )
    }
}
