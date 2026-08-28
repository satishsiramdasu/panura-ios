import SwiftUI
import GoogleCast

/// The cast icon, drawn rather than borrowed.
///
/// SF Symbols has no cast glyph — `tv` is a television, `airplayvideo` is
/// AirPlay, and neither says "send this to a TV" the way the screen-and-waves
/// mark does. That mark is what Android uses (Material's `Cast`), what the Cast
/// SDK's own button draws, and what every user already reads as casting, so the
/// app draws it: a screen outline with three waves radiating from its lower
/// left, filled in when something is connected.
struct CastGlyph: View {
    var connected = false
    /// Line weight, at the 24pt reference size. Scales with the frame.
    var weight: CGFloat = 1.9

    var body: some View {
        GeometryReader { geo in
            let u = min(geo.size.width, geo.size.height) / 24
            let line = weight * u
            let screen = CGRect(x: 2 * u, y: 4 * u, width: 20 * u, height: 16 * u)
            // The waves sit inside the screen's lower-left rather than outside
            // it: kept within the box, the mark stays legible at 17pt, which is
            // the size it is actually used at.
            let origin = CGPoint(x: screen.minX + 3.4 * u, y: screen.maxY - 3.4 * u)

            ZStack {
                RoundedRectangle(cornerRadius: 3 * u)
                    .strokeBorder(style: StrokeStyle(lineWidth: line))
                    .frame(width: screen.width, height: screen.height)
                    .position(x: screen.midX, y: screen.midY)

                if connected {
                    // Material's CastConnected: the same outline with the screen
                    // lit, so connected and idle differ by fill, not by shape.
                    RoundedRectangle(cornerRadius: 1.5 * u)
                        .frame(width: screen.width - 5.5 * u, height: screen.height - 5.5 * u)
                        .position(x: screen.midX + 1.2 * u, y: screen.midY - 1.2 * u)
                        .opacity(0.9)
                }

                // Dot, then two arcs — quarter circles opening up and to the
                // right, which is where the screen is.
                Circle()
                    .frame(width: 2.3 * u, height: 2.3 * u)
                    .position(origin)
                ForEach([CGFloat(4.6), CGFloat(8.0)], id: \.self) { radius in
                    Path { path in
                        path.addArc(
                            center: origin, radius: radius * u,
                            startAngle: .degrees(-90), endAngle: .degrees(0),
                            clockwise: false
                        )
                    }
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The standard Cast button, usable in any toolbar. Wraps GCKUICastButton.
struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = UIColor(PanuraTheme.accent)
        return button
    }
    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}

/// The app's cast control, top-right on every screen — the same slot and the
/// same job as Android's toolbar cast icon.
///
/// Deliberately not `CastButton` (GCKUICastButton): that one knows about
/// Chromecast and nothing else, so on a phone linked to a Panura TV it showed
/// "not connected" while a cast was running. This reflects whichever path is up
/// and opens the screen that can act on it — the controls when something is
/// actually playing, the picker when nothing is.
struct CastToolbarButton: View {
    @EnvironmentObject private var cast: CastManager
    @ObservedObject private var panura = PanuraCastManager.shared
    @State private var showPicker = false
    @State private var showControls = false

    private var connected: Bool { cast.isConnected || panura.isTVConnected }
    /// Something is on the TV right now, so the remote is the useful screen.
    private var playing: Bool { panura.isCasting }

    var body: some View {
        Button {
            if playing { showControls = true } else { showPicker = true }
        } label: {
            CastGlyph(connected: connected)
                .frame(width: 22, height: 22)
                .foregroundStyle(connected ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
                // Says "trying", without a second glyph: the phone is
                // discoverable but no TV has answered yet.
                .opacity(!connected && panura.isAdvertising ? 0.55 : 1)
        }
        .accessibilityLabel(connected ? "Casting — open cast controls" : "Cast to TV")
        .sheet(isPresented: $showPicker) {
            NavigationStack { CastDevicesView() }
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showControls) {
            PanuraCastControlView().presentationDragIndicator(.visible)
        }
    }
}

/// Cast screen, in two steps: pick how you want to connect, then do it.
///
/// Ported from Android's rebuilt cast dialog. The two paths are not equivalent
/// and the screen now says so up front — Panura Cast plays anything this app can
/// play, because the TV is running the same player, while Chromecast is limited
/// to what the receiver's own pipeline accepts. Offering them as an undifferentiated
/// list of devices hid the single most useful fact about the choice.
struct CastDevicesView: View {
    @EnvironmentObject private var cast: CastManager
    @ObservedObject private var panura = PanuraCastManager.shared
    @State private var showControls = false
    /// nil = the picker. Seeded from live state so reopening mid-connect resumes
    /// the Panura wait rather than dropping back to the choice.
    @State private var method: Method?

    private enum Method { case panura, chromecast }

    var body: some View {
        List {
            if cast.isConnected || panura.isTVConnected {
                connectedSection
            } else {
                switch method {
                case .none: pickerSection
                case .panura: panuraSection
                case .chromecast: chromecastSection
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Back to the picker, abandoning any in-flight Panura attempt — the
            // advertise has to stop with it or the header keeps blinking.
            if method != nil, !cast.isConnected, !panura.isTVConnected {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") {
                        if method == .panura { panura.stop() }
                        method = nil
                    }
                }
            }
        }
        .sheet(isPresented: $showControls) { PanuraCastControlView() }
        .onAppear {
            // Reopening while a link is in flight resumes that path.
            if panura.isAdvertising || panura.isTVConnected { method = .panura }
        }
    }

    private var title: String {
        if cast.isConnected || panura.isTVConnected { return "Connected" }
        switch method {
        case .panura: return "Panura Cast"
        case .chromecast: return "Chromecast"
        case .none: return "Cast to TV"
        }
    }

    // MARK: step 1 — how do you want to connect?

    private var pickerSection: some View {
        Section {
            methodCard(
                title: "Panura Cast",
                subtitle: "Plays through the Panura app on your Android TV or Fire TV",
                note: "Works with any stream — direct play, subtitles, full remote control.",
                noteGood: true,
                recommended: true,
                // Panura's own mark, because that is literally what this path
                // needs: the Panura app, running on the TV.
                icon: { Image("AppLogo").resizable().scaledToFit() }
            ) {
                method = .panura
                panura.start()
            }
            methodCard(
                title: "Chromecast",
                subtitle: "Built-in Chromecast, dongle or Google TV",
                note: "Limited stream support.",
                noteGood: false,
                recommended: false,
                // The generic cast mark — which is Google Cast's own.
                icon: { CastGlyph() }
            ) {
                method = .chromecast
            }
        } header: {
            Text("Choose how you want to connect")
        }
    }

    private func methodCard<Icon: View>(
        title: String,
        subtitle: String,
        note: String,
        noteGood: Bool,
        recommended: Bool,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    icon()
                        .frame(width: 26, height: 26)
                        .foregroundStyle(PanuraTheme.accent)
                    Text(title).font(.headline)
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(PanuraTheme.accentSoft, in: Capsule())
                            .foregroundStyle(PanuraTheme.accent)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                Label(note, systemImage: noteGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(noteGood ? Color.green : Color.orange)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: step 2a — Panura Cast

    private var panuraSection: some View {
        Section {
            // The two states are distinct and the difference matters: we can be
            // discoverable with no TV listening, and a cast then goes nowhere.
            // Say which one is true rather than one "connected".
            if panura.isAdvertising {
                Label("Discoverable — waiting for a TV…", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            } else if panura.isServerRunning {
                // Sockets are up but Bonjour has not published: the TV cannot
                // possibly find us, and saying "waiting" would point the user at
                // the TV for a fault that is on this device.
                Label("Not discoverable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(PanuraTheme.tertiary)
            } else {
                Button("Make this phone discoverable") { panura.start() }
            }

            // The address the TV must reach. If this is absent or on a different
            // subnet from the TV, discovery cannot work whatever the app does.
            if panura.isServerRunning, let ip = PanuraCastServer.localIPv4() {
                LabeledContent("This device", value: ip).font(.footnote)
            }

            if let error = panura.lastError {
                Text(error).font(.footnote).foregroundStyle(PanuraTheme.error)
                Button {
                    // Deep-links to Panura's own settings page, where the Local
                    // Network toggle lives.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Panura settings", systemImage: "gear")
                }
            }

            Toggle("Always cast through this phone", isOn: $panura.forceProxy).font(.footnote)
            proxyLog
        } header: {
            Text("Linking to the Panura app on your TV")
        } footer: {
            Text("Open Panura on your Android TV and it will find this phone on the "
                 + "same Wi-Fi. The phone serves the video, so it must stay on the "
                 + "network while playing.")
        }
    }

    // MARK: step 2b — Chromecast

    private var chromecastSection: some View {
        Section {
            CastButton().frame(height: 40)
        } header: {
            Text("Pick a device on your network")
        } footer: {
            Text("Tap the Cast icon to pick a TV. Chromecast plays fewer stream "
                 + "types than Panura Cast — if a video refuses to start, try "
                 + "Panura Cast instead.")
        }
    }

    // MARK: connected

    private var connectedSection: some View {
        Section {
            if panura.isTVConnected {
                HStack(spacing: 10) {
                    Image("AppLogo").resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                    Text(panura.connectedTVName.isEmpty
                         ? "Panura TV connected" : panura.connectedTVName)
                }
                if panura.isCasting, !panura.streamTitle.isEmpty {
                    Label(panura.streamTitle, systemImage: "play.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if panura.isCasting {
                    Button {
                        showControls = true
                    } label: { Label("Open controls", systemImage: "slider.horizontal.3") }
                }
            }
            if cast.isConnected {
                HStack(spacing: 10) {
                    CastGlyph(connected: true)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(PanuraTheme.accent)
                    Text(cast.connectedDeviceName ?? "Chromecast connected")
                }
            }

            // Disconnect ends whichever path is actually up. It used to call
            // PanuraCast's teardown unconditionally, which does nothing at all to
            // a Cast session — so on a Chromecast the button left the device
            // connected.
            Button("Disconnect", role: .destructive) {
                if cast.isConnected { cast.endSession() }
                if panura.isTVConnected || panura.isAdvertising { panura.stop() }
                method = nil
            }
            proxyLog
        } footer: {
            Text("Ready — play a video to start casting.")
        }
    }

    @ViewBuilder
    private var proxyLog: some View {
        if !panura.proxyLog.isEmpty {
            DisclosureGroup("Cast log (\(panura.proxyLog.count))") {
                ForEach(panura.proxyLog, id: \.self) { line in
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
        }
    }
}
