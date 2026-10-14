import SwiftUI
import UIKit

/// The system's own close button, for every sheet and page that closes.
///
/// One control everywhere: sheets had grown a "Done" here, a bare cross there
/// and a cross in a circle on the cast page. iOS 26 draws its close role in
/// the toolbar style of the release; before that, UIKit's close button is the
/// grey cross in a circle the system's own sheets use.
struct SheetCloseButton: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            SystemCloseButton(action: action)
                .frame(width: 30, height: 30)
                .accessibilityLabel("Close")
        }
    }
}

private struct SystemCloseButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .close)
        let coordinator = context.coordinator
        button.addAction(UIAction { _ in coordinator.action() }, for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}
