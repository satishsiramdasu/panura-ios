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
/// Web and Videos are captioned whether or not you are on them — they are the
/// two places you switch between, and a bar that names them says what the app
/// is for. Home is never captioned: a house needs no word under it, and neither
/// does the grid, which is a control rather than a place.
///
/// The exception is a destination that lives behind the grid. It borrows a pill
/// of its own, and while it is showing the two captions step aside — the bar
/// carries one label, and it is the one saying where you are.
///
/// It reserves its height rather than overlaying the page: a screen that does
/// not scroll can never scroll out from under an overlay, which would put the
/// bottom of those screens permanently out of reach.
struct AppBarRow: View {
    let selection: AppDestination
    let menuOpen: Bool
    let onSelect: (AppDestination) -> Void
    let onToggleMenu: () -> Void

    /// 48, same as Android's row.
    static let height: CGFloat = 48
    /// What the bar keeps under itself instead of the full home-indicator inset.
    ///
    /// The shell hands the bar that whole inset (`ignoresSafeArea` on the stack)
    /// and it gives back only this. The untrimmed 34pt left an empty band under
    /// the bar two thirds as tall as the bar itself; 8pt went too far the other
    /// way, and the system's home-indicator — which is drawn over everything,
    /// by the system, whatever the app puts there — landed on the pills. 16pt
    /// is the smallest strip that keeps the indicator clear of them: the pill's
    /// lower edge then sits ~21pt up, and the indicator tops out around 13pt.
    static let bottomInset: CGFloat = 16
    /// Everything the bar takes out of the screen. What the menu panel sits on.
    static var totalHeight: CGFloat { height + bottomInset }

    /// A grid destination takes the bar's caption for itself, so the standing
    /// seats give theirs up while it is showing.
    private var captionsVisible: Bool { !selection.livesBehindGrid }

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            // Glyph-only, always — one of the bar's two fixed points, and a
            // house says "home" without help.
            seat(.home, captioned: false)
            seat(.web, captioned: captionsVisible)
            seat(.videos, captioned: captionsVisible)
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
        // Padding inside the background, so the bar's own colour runs down to
        // the screen edge and the strip below it reads as the bar, not a gap.
        .padding(.bottom, Self.bottomInset)
        .background(PanuraTheme.surfaceContainer)
    }

    private func seat(_ destination: AppDestination, captioned: Bool) -> some View {
        let selected = selection == destination
        return pill(
            icon: destination.icon(selected: selected),
            label: captioned ? destination.barTitle : nil,
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
                        // Two captions plus two anchors is a tight row on the
                        // narrowest phones; the words shrink rather than clip.
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(selected ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
            .frame(height: 38)
            .padding(.horizontal, label == nil ? 12 : 14)
            // Every wordless seat is sized like the Home anchor, so the bar's
            // glyph buttons read as one family wherever they sit. Android sets
            // the same floor.
            .frame(minWidth: label == nil ? 52 : 0)
            .background(
                Capsule().fill(selected ? PanuraTheme.accentSoft : Color.clear)
            )
            // The capsule is only painted when selected; without this the
            // unselected seats are tappable on their glyph alone.
            .contentShape(Capsule())
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
