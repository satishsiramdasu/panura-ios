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
        .castPicker(isPresented: $showPicker)
        .sheet(isPresented: $showControls) {
            CastSessionView()
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
/// The SDK's own dialog is gone: it was a sheet, a screen, a button and then a
/// dialog to reach a device this card can name itself.
///
/// Nothing is scanned until asked. Discovery is a live multicast on the local
/// network, and someone opening this to reach their Panura TV has no reason to
/// pay for a Chromecast sweep.
struct CastDevicesView: View {
    @EnvironmentObject private var cast: CastManager
    @ObservedObject private var panura = PanuraCastManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = false
    /// Scanning starts on a tap, never on arrival. Discovery is a live multicast
    /// on the local network, and someone opening this to reach their Panura TV
    /// has no reason to pay for a Chromecast sweep.
    @State private var scanned = false

    /// One card, one screen.
    ///
    /// There used to be a second step — pick Chromecast, then look at a list —
    /// and it was a screen to say one thing. Both ways of reaching a television
    /// are here together, which is also the honest shape of the question: they
    /// are two devices to choose between, not two modes to enter.
    ///
    /// It hugs its content deliberately. Sized to fill, it became a full sheet
    /// with an empty half, which read as a screen that had failed to load
    /// something.
    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                if cast.isConnected || panura.isTVConnected {
                    connectedBody
                } else {
                    pickerBody
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 22).fill(PanuraTheme.surfaceContainer))
        .sheet(isPresented: $showControls) { CastSessionView() }
        // Whatever the way out — dismissing, connecting — the scan ends with the
        // screen. An idle scan costs battery and the SDK will not stop one on
        // its own.
        .onDisappear { cast.stopDiscovery() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            CastMark(connected: cast.isConnected || panura.isTVConnected)
                .frame(width: 22, height: 22)
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 40, height: 40)
                .background(
                    PanuraTheme.accent.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 11)
                )
            Text(cast.isConnected || panura.isTVConnected ? "Connected" : "Cast to TV")
                .font(.headline)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: the choice

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("RECOMMENDED", icon: "star.fill")

            deviceCard(
                title: "Panura on Android TV",
                subtitle: panuraSubtitle,
                busy: panura.isAdvertising,
                icon: { Image("AppLogo").resizable().scaledToFit() }
            ) {
                // Tapping it makes this phone findable. No second screen: the
                // row itself becomes the status, because "waiting for your TV"
                // is the only thing that screen ever said.
                if panura.isAdvertising { panura.stop() } else { panura.start() }
            }

            if let error = panura.lastError {
                notice(error, tone: .warn)
                wideButton("Open Panura's settings", icon: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } else {
                notice(
                    panura.isAdvertising
                        ? "Open Panura on your TV — it will find this phone on the same Wi-Fi."
                        : "Plays anything this app plays: every format, subtitles, and the full remote.",
                    tone: .good
                )
            }

            sectionLabel("NETWORK DEVICES", icon: "wifi")

            if !scanned {
                wideButton("Scan for devices", icon: "antenna.radiowaves.left.and.right") {
                    scanned = true
                    cast.startDiscovery()
                }
            } else if cast.devices.isEmpty {
                scanStatus
                wideButton("Scan again", icon: "arrow.clockwise") { cast.startDiscovery() }
            } else {
                ForEach(cast.devices) { device in
                    deviceCard(
                        title: device.name,
                        subtitle: (device.model?.isEmpty == false) ? device.model! : "Chromecast",
                        busy: cast.connecting == device.id,
                        icon: { CastMark() }
                    ) {
                        cast.connect(device)
                    }
                    .disabled(cast.connecting != nil)
                }
                wideButton("Scan again", icon: "arrow.clockwise") { cast.startDiscovery() }
            }

            notice(
                "Both devices must be on the same Wi-Fi, and Panura needs permission to find devices on it.",
                tone: .warn
            )
        }
    }

    private var panuraSubtitle: String {
        if panura.isAdvertising {
            return PanuraCastServer.localIPv4().map { "Waiting for your TV · " + $0 }
                ?? "Waiting for your TV…"
        }
        if panura.isServerRunning {
            // Sockets are up but Bonjour has not published: the TV cannot
            // possibly find us, and "waiting" would point at the TV for a fault
            // that is on this device.
            return "Not discoverable — tap to try again"
        }
        return "Google TV, Android TV and Fire TV"
    }

    private var scanStatus: some View {
        HStack(spacing: 10) {
            if cast.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            Text(cast.isScanning ? "Looking for TVs…" : "Nothing found on this network")
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(PanuraTheme.surfaceVariant))
    }

    // MARK: connected

    private var connectedBody: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(PanuraTheme.success).frame(width: 8, height: 8)
                Text(connectedName).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(PanuraTheme.surfaceVariant))

            if panura.isCasting, !panura.streamTitle.isEmpty {
                Label(panura.streamTitle, systemImage: "play.fill")
                    .font(.footnote)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if panura.isCasting || cast.isCasting {
                wideButton("Open controls", icon: "slider.horizontal.3") { showControls = true }
            } else {
                notice("Ready — play a video to send it over.", tone: .good)
            }

            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Text("Close")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12).fill(PanuraTheme.surfaceVariant)
                        )
                }
                .buttonStyle(.plain)

                // Disconnect ends whichever path is actually up. It used to call
                // PanuraCast's teardown unconditionally, which does nothing at
                // all to a Cast session — so on a Chromecast the button left the
                // device connected.
                Button {
                    if cast.isConnected { cast.endSession() }
                    if panura.isTVConnected || panura.isAdvertising { panura.stop() }
                    scanned = false
                } label: {
                    Text("Disconnect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(PanuraTheme.error))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectedName: String {
        if panura.isTVConnected {
            return panura.connectedTVName.isEmpty ? "Panura TV" : panura.connectedTVName
        }
        return cast.connectedDeviceName ?? "Chromecast"
    }

    // MARK: parts

    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.caption2.weight(.semibold)).kerning(0.6)
        }
        .foregroundStyle(PanuraTheme.onSurfaceVariant)
    }

    private func deviceCard<Icon: View>(
        title: String,
        subtitle: String,
        busy: Bool = false,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(PanuraTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        PanuraTheme.accent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(PanuraTheme.surfaceVariant))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// Filled rather than outlined.
    ///
    /// Everything on this card is already a rounded rectangle, and giving the
    /// buttons borders too put four competing outlines on one small panel. A
    /// tinted fill separates them from the device rows without adding a line.
    private func wideButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(PanuraTheme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(PanuraTheme.accent.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
    }

    private enum Tone { case good, warn }

    /// A tinted note rather than grey footer text, and no border on it either.
    ///
    /// The two things worth saying — what the recommended path is good for, and
    /// the Wi-Fi rule that breaks everything — are the difference between
    /// casting working and not, and footnote grey is where eyes skip.
    private func notice(_ text: String, tone: Tone) -> some View {
        let colour = tone == .good ? PanuraTheme.success : PanuraTheme.tertiary
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .good ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 12))
            Text(text).font(.caption2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(colour)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(colour.opacity(0.12)))
    }
}

/// Presents the cast picker as a centred dialog rather than a bottom sheet.
///
/// A sheet is for a task you work through; this is a question with two answers,
/// and Android's own cast picker is a dialog for the same reason. The clear
/// presentation background is iOS 16.4, so on anything older it stays an
/// ordinary sheet — the card inside is identical either way, and no one is left
/// without a way to pick a television.
struct CastPickerDialog: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if #available(iOS 16.4, *) {
                dialog
                    .presentationBackground(.clear)
                    .presentationDetents([.large])
            } else {
                dialog.presentationDragIndicator(.visible)
            }
        }
    }

    private var dialog: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            CastDevicesView()
                .padding(.horizontal, 16)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
    }
}

extension View {
    /// The one way the cast picker is presented, everywhere it is presented.
    func castPicker(isPresented: Binding<Bool>) -> some View {
        modifier(CastPickerDialog(isPresented: isPresented))
    }
}


/// The cast card on Home.
///
/// Casting was reachable only from the mark in a header — a 23-point glyph that
/// says nothing about what it does until you already know. It is one of the two
/// things this app is for, so Home states it: what it is, which television is
/// connected, and a button that starts the search.
///
/// One card for both paths on purpose. Which of Panura Cast and Chromecast is
/// in use is a detail of how the video gets there, and `CastDevicesView` is
/// where that choice is made and explained. Here there is only a television.
struct CastHomeCard: View {
    @ObservedObject private var cast = CastManager.shared
    @ObservedObject private var panura = PanuraCastManager.shared
    @State private var showPicker = false
    @State private var showControls = false

    private var connected: Bool { cast.isConnected || panura.isTVConnected }
    private var casting: Bool { cast.isCasting || panura.isCasting }

    private var deviceName: String? {
        if panura.isTVConnected, !panura.connectedTVName.isEmpty { return panura.connectedTVName }
        return cast.connectedDeviceName
    }

    private var title: String {
        guard connected else { return "Cast to TV" }
        return deviceName ?? "Connected"
    }

    private var subtitle: String {
        if casting {
            let playing = panura.isCasting ? panura.streamTitle : (cast.castingTitle ?? "")
            return playing.isEmpty ? "Playing" : playing
        }
        if connected { return "Connected — play a video to send it over" }
        // Named, because the difference decides what will actually play, and
        // the picker is where it is explained properly.
        return "Panura on Android TV, or any Chromecast"
    }

    /// Controls once something is on the TV; otherwise the picker, which is
    /// also where a connected-but-idle session is switched or dropped.
    private var action: String { casting ? "Controls" : (connected ? "Change" : "Find device") }

    var body: some View {
        Button {
            if casting { showControls = true } else { showPicker = true }
        } label: {
            HStack(spacing: 12) {
                CastMark(connected: connected)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(connected ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
                    .frame(width: 42, height: 42)
                    .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(action)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PanuraTheme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(PanuraTheme.accent, in: Capsule())
            }
            .padding(12)
            .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(connected ? "Casting to \(title)" : "Cast to TV")
        .castPicker(isPresented: $showPicker)
        .sheet(isPresented: $showControls) {
            CastSessionView()
        }
    }
}
