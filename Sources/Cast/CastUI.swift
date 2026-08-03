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
    @ObservedObject private var panura = PanuraCastManager.shared
    @State private var showControls = false

    var body: some View {
        List {
            Section {
                if cast.isConnected {
                    Label(cast.connectedDeviceName ?? "Connected", systemImage: "tv.fill")
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
                CastButton().frame(height: 40)
            } header: {
                Text("Chromecast")
            } footer: {
                Text("Tap the Cast icon to pick a TV on your network.")
            }

            Section {
                // The two states are distinct and the difference matters: we can
                // be discoverable with no TV listening, and a cast then goes
                // nowhere. Say which one is true rather than one "connected".
                if panura.isTVConnected {
                    Label(
                        panura.connectedTVName.isEmpty ? "Panura TV connected" : panura.connectedTVName,
                        systemImage: "tv.fill"
                    )
                    if panura.isCasting, !panura.streamTitle.isEmpty {
                        Label(panura.streamTitle, systemImage: "play.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if panura.isAdvertising {
                    Label("Waiting for a TV…", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Off").foregroundStyle(.secondary)
                }

                if panura.isCasting {
                    Button {
                        showControls = true
                    } label: {
                        Label("Open controls", systemImage: "slider.horizontal.3")
                    }
                }

                if panura.isAdvertising {
                    Button("Stop", role: .destructive) { panura.stop() }
                } else {
                    Button("Make this phone discoverable") { panura.start() }
                }

                if let error = panura.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Panura Android TV")
            } footer: {
                Text("Open Panura on your Android TV and it will find this phone "
                     + "on the same Wi-Fi. The phone serves the video, so it must "
                     + "stay on the network while playing.")
            }
        }
        .navigationTitle("Cast to TV")
        .sheet(isPresented: $showControls) { PanuraCastControlView() }
    }
}
