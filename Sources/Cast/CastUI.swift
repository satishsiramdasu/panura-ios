import SwiftUI
import GoogleCast

/// The standard Cast button, usable in any toolbar. Wraps GCKUICastButton.
struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = UIColor(PanuraTheme.accent)
        return button
    }
    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}

/// Simple device / connection status screen reachable from Settings.
struct CastDevicesView: View {
    @EnvironmentObject private var cast: CastManager
    var body: some View {
        List {
            Section("Status") {
                if cast.isConnected {
                    Label(cast.connectedDeviceName ?? "Connected", systemImage: "tv.fill")
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
            }
            Section {
                CastButton().frame(height: 40)
            } footer: {
                Text("Tap the Cast icon to pick a TV on your network.")
            }
        }
        .navigationTitle("Cast to TV")
    }
}
