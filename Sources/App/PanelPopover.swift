import SwiftUI

/// The app's two panels — the browser's site controls and the cast picker —
/// presented the way iOS presents a panel that belongs to a button.
///
/// Both were hand-built: a full-screen overlay, our own scrim, our own corner
/// shape, our own transition, and a clear strip over the header so the bar
/// underneath could not be pressed. All of that is what a popover already is,
/// and it does two things the overlay never did — it grows out of the control
/// that opened it, and it points back at that control with an arrow. Those are
/// exactly what the confirmation dialogs elsewhere in the app do, which is the
/// look being matched here.
///
/// The system also supplies the background, which is lighter than the header it
/// sits under, so the panel separates from the bar without a shadow under it.
///
/// `presentationCompactAdaptation(.popover)` is the whole trick: without it a
/// popover on a phone turns into a sheet from the bottom, which is the shape
/// this is moving away from. It needs iOS 16.4, which is why the app's floor is
/// 16.4 — there is no fallback path to keep working.
enum PanelPopover {
    /// Wide enough for a device name or a site's controls, never the width of
    /// the screen: a panel that spans the screen reads as a new screen.
    static var width: CGFloat { min(UIScreen.main.bounds.width - 56, 380) }
}

extension View {
    /// Presents `content` as a panel hanging off this view, arrow and all.
    func panelPopover<C: View>(
        isPresented: Binding<Bool>,
        width: CGFloat = PanelPopover.width,
        tint: Color? = nil,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        popover(
            isPresented: isPresented,
            attachmentAnchor: .rect(.bounds),
            // The edge of the button the panel comes out of, so the arrow ends
            // up under the mark rather than beside it.
            arrowEdge: .bottom
        ) {
            content()
                .frame(width: width)
                .modifier(PanelPopoverChrome(tint: tint))
        }
    }
}

/// Keeps it a popover on a phone, and lets private browsing repaint it.
private struct PanelPopoverChrome: ViewModifier {
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let tint {
            content
                .presentationCompactAdaptation(.popover)
                .presentationBackground(tint)
        } else {
            content.presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - which destination is on screen

/// True while the destination this view belongs to is the one being shown.
///
/// All five destinations are composed at once and hidden with opacity, so five
/// copies of the header — and five cast marks — exist at every moment. A panel
/// bound to a shared flag would otherwise be presented from all of them at the
/// same time, and iOS presents one and drops the rest on the floor, which is
/// not a thing to leave to luck.
private struct DestinationActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var destinationIsActive: Bool {
        get { self[DestinationActiveKey.self] }
        set { self[DestinationActiveKey.self] = newValue }
    }
}
