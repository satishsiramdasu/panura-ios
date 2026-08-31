import SwiftUI
import GoogleCast

/// Material's `connected_tv` (sharp), drawn: a TV on a stand with the cast
/// waves inside its lower-left corner.
///
/// The app's one cast icon, in every place casting appears — header, detection
/// bar, sheet, picker, device rows — and the same mark Android uses
/// (`PanuraIcons.ConnectedTv`), so a screenshot from either phone shows the
/// same button. It is drawn rather than borrowed because SF Symbols has no cast
/// glyph and the Cast SDK's button hides itself when no device is around, which
/// is exactly when the user needs to see it.
///
/// It says both things a TV icon alone cannot: this is a television, and
/// something is being sent to it. `connected` lights the screen.
struct CastMark: View {
    var connected = false
    /// Stroke weight at the 24pt reference size; scales with the frame.
    var weight: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let u = min(geo.size.width, geo.size.height) / 24
            let line = weight * u
            // Sharp, as in the sharp variant — square corners throughout.
            let screen = CGRect(x: 1 * u, y: 3 * u, width: 22 * u, height: 16 * u)
            let inner = screen.insetBy(dx: line, dy: line)
            // The waves start from the inside of the lower-left corner.
            let corner = CGPoint(x: inner.minX + 2 * u, y: inner.maxY - 2 * u)

            ZStack(alignment: .topLeading) {
                if connected {
                    Rectangle()
                        .frame(width: inner.width, height: inner.height)
                        .opacity(0.28)
                        .offset(x: inner.minX, y: inner.minY)
                }

                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: line))
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: screen.minX, y: screen.minY)

                // The stand, which is what makes this a television rather than
                // a window.
                Rectangle()
                    .frame(width: 8 * u, height: line)
                    .offset(x: 8 * u, y: screen.maxY)

                // Innermost wave: solid, as in the original.
                Path { path in
                    path.move(to: corner)
                    path.addArc(
                        center: corner, radius: 3 * u,
                        startAngle: .degrees(-90), endAngle: .degrees(0),
                        clockwise: false
                    )
                    path.closeSubpath()
                }

                ForEach([CGFloat(5.2), CGFloat(8.2)], id: \.self) { radius in
                    Path { path in
                        path.addArc(
                            center: corner, radius: radius * u,
                            startAngle: .degrees(-90), endAngle: .degrees(0),
                            clockwise: false
                        )
                    }
                    .stroke(style: StrokeStyle(lineWidth: line, lineCap: .butt))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The app's cast control, top-right on every screen — the same slot and the
/// same job as Android's toolbar cast icon.
///
/// Deliberately not the SDK's `GCKUICastButton`: that one knows about Chromecast
/// and nothing else, so on a phone linked to a Panura TV it showed "not
/// connected" while a cast was running — and it hides itself entirely when no
/// Cast device is around. This reflects whichever path is up and opens the
/// screen that can act on it — the controls when something is actually playing,
/// the picker when nothing is.
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
            CastMark(connected: connected)
                .frame(width: 23, height: 23)
                .foregroundStyle(connected ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
                // Says "trying", without a second glyph: the phone is
                // discoverable but no TV has answered yet.
                .opacity(!connected && panura.isAdvertising ? 0.55 : 1)
        }
        .accessibilityLabel(connected ? "Playing on TV — open controls" : "Play on TV")
        .sheet(isPresented: $showPicker) {
            NavigationStack { CastDevicesView() }
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showControls) {
            PanuraCastControlView().presentationDragIndicator(.visible)
        }
    }
}

/// The cast screen.
///
/// Ported from Android's rebuilt cast dialog. The two paths are not equivalent
/// and the screen says so up front — Panura Cast plays anything this app can
/// play, because the TV is running the same player, while Chromecast is limited
/// to what the receiver's own pipeline accepts. Offering them as an
/// undifferentiated list of devices hid the single most useful fact about the
/// choice.
///
/// Picking Chromecast starts the scan and lists what it finds, right there —
/// one tap to a TV. The SDK's own dialog is gone: it was a sheet, a screen, a
/// button and then a dialog to reach a device this screen can name itself.
///
/// The scan runs only from that tap, never on arrival. Discovery is a live
/// multicast on the local network, and someone opening this screen to reach
/// their Panura TV has no reason to pay for a Chromecast sweep.
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
                case .chromecast: chromecastDevicesSection
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
                        if method == .chromecast { cast.stopDiscovery() }
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
        // Whatever the way out — Back, dismissing the sheet, connecting — the
        // scan ends with the screen. An idle scan costs battery and the SDK
        // will not stop one on its own.
        .onDisappear { cast.stopDiscovery() }
    }

    private var title: String {
        if cast.isConnected || panura.isTVConnected { return "Connected" }
        switch method {
        case .panura: return "Panura Cast"
        case .chromecast: return "Chromecast"
        case .none: return "Play on TV"
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
                // The real Cast mark, because here it means Google Cast and
                // nothing else — beside Panura's own mark, the two icons say
                // which protocol each row is.
                icon: { CastMark() }
            ) {
                method = .chromecast
                // The scan starts here, on the tap, and nowhere else.
                cast.startDiscovery()
            }
        } header: {
            Text("Choose how you want to play")
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

    // MARK: step 2b — the Chromecast devices themselves

    /// Every Cast target on the network, one tap each.
    ///
    /// The scan says it is running rather than showing an empty list: a TV takes
    /// a couple of seconds to answer, and "no devices" arriving instantly would
    /// be a lie for most of that time.
    private var chromecastDevicesSection: some View {
        Section {
            if cast.devices.isEmpty {
                HStack(spacing: 10) {
                    if cast.isScanning { ProgressView().controlSize(.small) }
                    Text(cast.isScanning ? "Looking for TVs…" : "No Cast devices found")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(cast.devices) { device in
                    Button {
                        cast.connect(device)
                    } label: {
                        HStack(spacing: 10) {
                            CastMark()
                                .frame(width: 22, height: 22)
                                .foregroundStyle(PanuraTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.subheadline)
                                if let model = device.model, !model.isEmpty {
                                    Text(model)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            if cast.connecting == device.id {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(cast.connecting != nil)
                }
            }
        } header: {
            Text("Cast devices")
        } footer: {
            Text("On the same Wi-Fi as this phone. If a TV is missing, check that "
                 + "Panura is allowed to find devices on the local network.")
        }
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
                    CastMark(connected: true)
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
