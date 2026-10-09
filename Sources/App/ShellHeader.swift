import SwiftUI

/// The app's one permanent row, above the tabs and above everything else.
///
///     [ mark ] Panura                        [ cast ] [ menu ]
///              Browse, play, cast
///
/// It replaces the per-screen header as the place the app's own controls live.
/// Screens still draw a bar of their own where they need one — the browser's
/// address pill above all — but that bar is now about the screen, not about the
/// app, which is why the mark, the cast control and the menu came up here and
/// stopped being repeated four times.
///
/// The left cell is identity and the right cell is the two things that are true
/// everywhere: where the video can go, and everything that is not a place.
struct ShellHeader<MenuContent: View>: View {
    /// Shown instead of the tagline once there is a television to name. The
    /// tagline is for someone who has just arrived; a connected TV is for
    /// someone in the middle of something, and that always wins.
    var connectedTV: String?
    /// The rows behind the menu button, supplied by the shell so this view
    /// stays about layout. Wrapped in a `Menu` here rather than passed a
    /// closure: a `Menu` anchors beside the control it belongs to on both
    /// platforms, where a `confirmationDialog` becomes a bottom sheet on a
    /// phone and points at nothing.
    @ViewBuilder var menu: MenuContent

    static var height: CGFloat { 58 }

    var body: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Panura")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PanuraTheme.onSurface)
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            castButton
            menuButton
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(PanuraTheme.surfaceContainer)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let connectedTV, !connectedTV.isEmpty {
            HStack(spacing: 4) {
                // A filled dot, not a glyph: the cast control to the right is
                // already the glyph, and two of them side by side would read as
                // two different states rather than one.
                Circle()
                    .fill(PanuraTheme.accent)
                    .frame(width: 6, height: 6)
                Text(connectedTV)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PanuraTheme.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text("Browse, play, cast")
                .font(.system(size: 12))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .lineLimit(1)
        }
    }

    /// Opens the picker, or the remote once something is playing — both of
    /// which `CastToolbarButton` already decides, so this only has to be the
    /// button the header draws.
    private var castButton: some View {
        CastToolbarButton()
            .frame(width: 40, height: 40)
    }

    /// Everything that is not a place: Settings, About, Help, Report, Rate.
    ///
    /// A `Menu`, not a drawer. The tabs below are the navigation now, and a
    /// drawer that listed destinations beside them would be two mechanisms for
    /// one job — which is the thing the drawer was built to stop.
    private var menuButton: some View {
        Menu {
            menu
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .frame(width: 40, height: 40)
                .background(PanuraTheme.surfaceContainerHigh, in: Circle())
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Menu")
    }
}
