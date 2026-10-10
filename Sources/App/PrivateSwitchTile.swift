import SwiftUI

/// The private-browsing switch, as a labelled tile beside an address field.
///
/// It used to be a pair of spectacles inside the field: a second target in the
/// middle of the one control you are meant to press, announcing a mode by
/// changing colour — which only tells you anything if you already know the
/// code. A tile says what it is and shows what it is set to, and leaves the
/// field to be a field.
///
/// Shared by Home and the browser deliberately. They are the two places a
/// session is started and the two places it must be visible, and a switch that
/// looked or behaved differently between them would be a second switch as far
/// as anybody reading it is concerned. The *consequence* differs — Home has no
/// page to close — so that is a parameter, and only that.
struct PrivateSwitchTile: View {
    let on: Bool
    /// Whether there is a page that switching would take away. With none, the
    /// switch has no consequence worth a question and flips on the first tap;
    /// a menu that always opened would put a step in front of a toggle.
    let hasPage: Bool
    /// The fill of the field beside it, so the two read as one control split
    /// in two rather than a field with a button parked next to it.
    let fill: Color
    var height: CGFloat = 46
    /// `keepPage` is what the chosen menu row meant. Called with `true` when
    /// there was nothing to keep.
    let onSwitch: (Bool) -> Void

    var body: some View {
        Group {
            // A menu, not a confirmation dialog. A dialog appears where the
            // system decides — a sheet from the bottom of the phone, or on an
            // iPad a popover aimed at the root of the screen, hanging in the
            // middle pointing at nothing. A menu opens on its own label,
            // beside the control that raised it, on both.
            if hasPage {
                Menu {
                    Section(PrivateSwitch.message(turningOn: !on)) {
                        Button { onSwitch(true) } label: {
                            Label("Keep this page", systemImage: "doc")
                        }
                        Button(role: .destructive) { onSwitch(false) } label: {
                            Label("Close it", systemImage: "xmark")
                        }
                    }
                } label: {
                    tile
                }
                .menuOrder(.fixed)
            } else {
                Button { onSwitch(true) } label: { tile }
                    .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(on ? "Turn off private browsing" : "Private browsing")
    }

    private var tile: some View {
        VStack(spacing: 4) {
            Text("PRIVATE")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(on ? PanuraTheme.incognito : PanuraTheme.onSurfaceVariant)
            MiniSwitch(on: on, tint: PanuraTheme.incognito)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
