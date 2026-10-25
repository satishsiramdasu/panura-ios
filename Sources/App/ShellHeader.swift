import SwiftUI

/// The app's one permanent row, and since the tab strip came out, the only
/// thing on screen that says where you are.
///
///     ╭──────────────────────╮
///     │ [mark] Panura v1.1   │                  [cast] [menu]
///     │  ◉ WEB BROWSER ⌄     │
///
/// **The seat.** The block holding the mark is drawn as the strip's selected
/// tab was — the seat colour, rounded at the top, running to the bottom edge —
/// because with one destination open at a time there is one seat, and the mark
/// sits in it. It hugs its contents rather than spanning the row, or it reads
/// as a bar rather than a tab.
///
/// **The seat is the switcher.** A logo on its own is not legibly a button, so
/// the line under the name says which section you are in, with that section's
/// glyph in its colour and a chevron, which is the shape every title switcher
/// uses. Tapping it lists the places the app has (see `ShellSwitcher`).
///
/// Ported from Android's `ShellHeader`, which took the strip out first: it
/// spent its height on every screen keeping four labels permanently visible,
/// and most switching anybody does is Home to the browser and back, which
/// Home's own search row already does in one tap.
struct ShellHeader<MenuContent: View>: View {
    /// The section on screen, named on the line under the app's name.
    let section: AppDestination
    /// Joins the section rather than replacing it: with only the TV's name
    /// there, nothing said whether you were in the browser or your videos.
    var connectedTV: String?
    /// The ground: neutral everywhere, violet for private browsing.
    var ground: Color = AppChrome.bar
    var seat: Color = AppChrome.seat
    let onSwitcher: () -> Void
    /// The rows behind the menu button, supplied by the shell so this view
    /// stays about layout. A `Menu` anchors beside the control it belongs to.
    @ViewBuilder var menu: MenuContent

    static var height: CGFloat { 58 }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        HStack(spacing: 0) {
            seatBlock
            Spacer(minLength: 8)
            // Their own row, each a 44-point target with nothing between them,
            // so the ink is spaced by the targets alone and evenly. With the
            // row's spacing added on top they sat wide and uneven.
            HStack(spacing: 0) {
                CastToolbarButton()
                    .frame(width: 44, height: 44)
                menuButton
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: Self.height)
        .background(ground)
    }

    private var seatBlock: some View {
        Button(action: onSwitcher) {
            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Panura")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(PanuraTheme.onSurface)
                        if !appVersion.isEmpty {
                            Text("v\(appVersion)")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(PanuraTheme.accent)
                        }
                    }
                    sectionLine
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(maxHeight: .infinity)
            .background(
                TopRoundedRectangle(radius: 20).fill(seat)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.placeName). Switch section")
    }

    private var sectionLine: some View {
        HStack(spacing: 4) {
            // The open section's own glyph, in its own colour. Home keeps the
            // app's tagline and no glyph: somebody who has just arrived is the
            // only person the tagline is for, and Home is where they are.
            if section != .home {
                Image(systemName: section.placeIcon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(section.markColor)
            }
            Text(section == .home ? "VIDEO BROWSER" : section.placeName.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .lineLimit(1)
            if let connectedTV, !connectedTV.isEmpty {
                Circle()
                    .fill(PanuraTheme.accent)
                    .frame(width: 5, height: 5)
                    .padding(.leading, 2)
                Text(connectedTV)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PanuraTheme.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 90, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
    }

    /// Everything that is not a place. A `Menu`, so it hangs off its button.
    /// A plain glyph at the cast mark's colour and weight: nothing in this row
    /// is more important than the rest, and a filled circle said it was.
    private var menuButton: some View {
        Menu {
            menu
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(PanuraTheme.onSurface)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Menu")
    }
}

/// The places this app has, hung under the header's seat.
///
/// What replaced the tab strip. Each row says what the place is for and wears
/// its colour — four identical grey glyphs would read as a settings menu — and
/// the open one is ticked, because this is the only surface left showing the
/// whole set: without the tick it is a launcher rather than navigation.
struct ShellSwitcher: View {
    let current: AppDestination
    let onSelect: (AppDestination) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            AnchoredPanel(side: .leading, pointerInset: 30, width: min(UIScreen.main.bounds.width - 24, 320)) {
                VStack(spacing: 0) {
                    ForEach(AppDestination.places, id: \.self) { place in
                        Button {
                            onDismiss()
                            onSelect(place)
                        } label: {
                            row(place)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            .padding(.leading, 12)
            .padding(.top, ShellHeader<EmptyView>.height - 6)
            .transition(.scale(scale: 0.86, anchor: .topLeading).combined(with: .opacity))
        }
    }

    private func row(_ place: AppDestination) -> some View {
        HStack(spacing: 14) {
            Image(systemName: place.placeIcon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(place.markColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.placeName)
                    .font(.body)
                    .foregroundStyle(PanuraTheme.onSurface)
                Text(place.placeTagline)
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if place == current {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PanuraTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// Rounded at the top only, running square into the bar beneath it.
/// `UnevenRoundedRectangle` would do this, from iOS 17; this app runs on 16.4.
struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
            startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension AppDestination {
    /// The sections the switcher lists, in order.
    static let places: [AppDestination] = [.home, .web, .videos, .ftp]

    /// As the switcher and the header name it — and Home's tiles agree.
    var placeName: String {
        switch self {
        case .web: return "Web Browser"
        // Not "Phone Videos": this runs on iPads too, and a label that
        // misdescribes the hardware is one somebody reads twice.
        case .videos: return "Local Videos"
        case .ftp: return "Media Servers"
        default: return title
        }
    }

    var placeTagline: String {
        switch self {
        case .home: return "Shortcuts and recent videos"
        case .web: return "Find something to play"
        case .videos: return "Files on this device"
        case .ftp: return "Playlists and network shares"
        default: return detail
        }
    }

    var placeIcon: String {
        switch self {
        case .home: return "house"
        case .web: return "globe"
        case .videos: return "film"
        case .ftp: return "server.rack"
        default: return icon(selected: false)
        }
    }

    /// The section's colour, at a weight that reads on a dark row. The seat
    /// colours are nearly black by design, and a glyph painted in one is a
    /// smudge.
    var markColor: Color {
        switch self {
        case .web: return Color(hex: 0xE8A33C)
        case .videos: return Color(hex: 0x59C98A)
        case .ftp: return Color(hex: 0xE58AB4)
        case .stream: return Color(hex: 0x4FC3D9)
        default: return PanuraTheme.accent
        }
    }
}
