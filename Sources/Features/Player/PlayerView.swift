import SwiftUI
import UIKit
import AVKit
import VLCKitSPM

/// Full-screen VLC player with a Panura-branded control overlay:
/// gesture seeking / brightness / volume, ±skip, aspect zoom, controls-lock,
/// orientation-lock, PiP, audio + subtitle tracks, and A-V sync — plus
/// resume-from-position handled by the model.
struct PlayerView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VLCPlayerModel()

    // Control visibility
    @State private var showControls = true
    @State private var locked = false
    @State private var lockRevealed = false
    @State private var hideTask: Task<Void, Never>?

    // Gesture HUD state
    @State private var seekPreview: Float?          // fraction while horizontal-dragging
    @State private var seekBase: Float = 0
    @State private var brightnessHUD: CGFloat?
    @State private var brightnessBase: CGFloat = 0
    @State private var volumeHUD: CGFloat?
    @State private var volumeBase: Float = 0
    @State private var speedBoosting = false
    @State private var flashZone: PlayerZone?
    @State private var hudClear: Task<Void, Never>?

    // Sheets / PiP
    @State private var sheet: PlayerSheet?
    @State private var pip: VLCPiPController?

    @AppStorage("subtitle_size") private var subtitleSize = 24
    @AppStorage("subtitle_color") private var subtitleColor = 0xFFFFFF

    enum PlayerSheet: Int, Identifiable { case audio, subtitles, sync; var id: Int { rawValue } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoView(model: model, item: item).ignoresSafeArea()
            // Mounts the hidden MPVolumeView so SystemVolume can drive it. Needs a
            // non-zero footprint for its UISlider to materialise; kept invisible.
            VolumeHost().frame(width: 1, height: 1).opacity(0.001).allowsHitTesting(false)

            gestureSurface.ignoresSafeArea()

            if let failure = model.failure {
                failureView(failure)
            } else if model.buffering && !speedBoosting {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            hudLayer.allowsHitTesting(false)

            if locked {
                lockOverlay
            } else if showControls {
                controlsOverlay.transition(.opacity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(item: $sheet) { s in
            sheetContent(s)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { OrientationManager.allowAll(); scheduleHide() }
        .onDisappear {
            OrientationManager.reset()
            pip?.teardown()
            model.stop()
        }
        .onChange(of: subtitleSize) { _ in model.reopenPreservingPosition() }
        .onChange(of: subtitleColor) { _ in model.reopenPreservingPosition() }
    }

    // MARK: gesture surface

    private var gestureSurface: some View {
        PlayerGestureSurface(
            onSingleTap: { toggleControls() },
            onDoubleTap: { handleDoubleTap($0) },
            onSeekBegan: {
                guard !locked else { return }
                seekBase = model.position; seekPreview = model.position; showControlsNow()
            },
            onSeekChanged: { dx in
                guard !locked, seekPreview != nil else { return }
                let total = model.totalSeconds
                guard total > 0 else { return }
                // Time-based, not fraction-based: a full-width swipe moves ~90s
                // regardless of length (it used to jump the whole video).
                let target = Double(seekBase) * total + Double(dx) * 90
                seekPreview = clamp01f(Float(target / total))
            },
            onSeekEnded: {
                guard !locked, let f = seekPreview else { return }
                model.seek(to: f); seekPreview = nil; scheduleHide()
            },
            onVerticalBegan: { beginVertical($0) },
            onVerticalChanged: { changeVertical($0) },
            onVerticalEnded: { endVertical() },
            onLongPressBegan: { beginBoost() },
            onLongPressEnded: { endBoost() }
        )
    }

    private func handleDoubleTap(_ zone: PlayerZone) {
        guard !locked else { toggleControls(); return }
        switch zone {
        case .left:  model.skipBackward(); flashSkip(.left)
        case .right: model.skipForward();  flashSkip(.right)
        case .center: model.togglePlay()
        }
        scheduleHide()
    }

    private func beginVertical(_ zone: PlayerZone) {
        guard !locked else { return }
        if zone == .left { brightnessBase = ScreenBrightness.level; brightnessHUD = brightnessBase }
        else { volumeBase = SystemVolume.shared.level; volumeHUD = CGFloat(volumeBase) }
    }
    private func changeVertical(_ d: CGFloat) {
        guard !locked else { return }
        if brightnessHUD != nil {
            let b = clamp01(brightnessBase + d); ScreenBrightness.set(b); brightnessHUD = b
        } else if volumeHUD != nil {
            let v = Float(clamp01(CGFloat(volumeBase) + d)); SystemVolume.shared.set(v); volumeHUD = CGFloat(v)
        }
    }
    private func endVertical() {
        hudClear?.cancel()
        hudClear = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation { brightnessHUD = nil; volumeHUD = nil }
        }
    }

    private func beginBoost() {
        guard !locked, model.isPlaying else { return }
        withAnimation { speedBoosting = true }; model.beginSpeedBoost()
    }
    private func endBoost() {
        guard speedBoosting else { return }
        withAnimation { speedBoosting = false }; model.endSpeedBoost()
    }

    private func flashSkip(_ zone: PlayerZone) {
        withAnimation(.easeOut(duration: 0.12)) { flashZone = zone }
        Task {
            try? await Task.sleep(nanoseconds: 480_000_000)
            withAnimation { if flashZone == zone { flashZone = nil } }
        }
    }

    // MARK: HUD layer

    private var hudLayer: some View {
        ZStack {
            if speedBoosting {
                Label("2×", systemImage: "forward.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 44)
            }
            if let f = seekPreview { seekHUD(f) }
            if let b = brightnessHUD {
                verticalHUD(icon: "sun.max.fill", value: b)
            }
            if let v = volumeHUD {
                verticalHUD(icon: v <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill", value: v)
            }
            skipFlash
        }
    }

    private func seekHUD(_ f: Float) -> some View {
        let total = model.totalSeconds
        let target = Double(f) * total
        let delta = target - model.elapsedSeconds
        return VStack(spacing: 4) {
            Text(VLCPlayerModel.clock(target)).font(.title2.monospacedDigit().bold())
            Text("\(delta >= 0 ? "+" : "-")\(VLCPlayerModel.clock(abs(delta)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func verticalHUD(icon: String, value: CGFloat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title3)
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.25)).frame(width: 5, height: 110)
                Capsule().fill(PanuraTheme.accent).frame(width: 5, height: max(3, 110 * value))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var skipFlash: some View {
        HStack {
            if flashZone == .left { skipBadge("gobackward").frame(maxWidth: .infinity) }
            if flashZone == .right {
                Spacer(); skipBadge("goforward").frame(maxWidth: .infinity)
            }
        }
    }
    private func skipBadge(_ system: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 30))
            Text("\(model.skipInterval)s").font(.caption.bold())
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(.ultraThinMaterial, in: Circle())
    }

    // MARK: controls overlay

    private var controlsOverlay: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .bottom).frame(height: 130)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom).frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerTransport
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            iconButton("xmark") { close() }
            Text(item.title).lineLimit(1).font(.headline)
            Spacer()
            if pipPossible { iconButton("pip.enter") { togglePiP() } }
            iconButton("lock.fill") { lock() }
        }
        .foregroundStyle(.white)
    }

    private var centerTransport: some View {
        HStack(spacing: 56) {
            skipButton(system: "gobackward") { model.skipBackward(); scheduleHide() }
            Button { model.togglePlay(); scheduleHide() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 56))
            }
            skipButton(system: "goforward") { model.skipForward(); scheduleHide() }
        }
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(displayElapsed).font(.caption.monospacedDigit())
                Slider(
                    value: Binding(
                        get: { Double(seekPreview ?? model.position) },
                        set: { seekPreview = Float($0) }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing { showControlsNow() }
                        else { if let f = seekPreview { model.seek(to: f) }; seekPreview = nil; scheduleHide() }
                    }
                )
                .tint(PanuraTheme.accent)
                // Time left (dimmed) stacked over total duration — matches Android.
                VStack(alignment: .trailing, spacing: 0) {
                    Text(model.remaining)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                    Text(model.total).font(.caption.monospacedDigit())
                }
            }
            HStack(spacing: 22) {
                quickAction("waveform", "Audio") { sheet = .audio }
                quickAction("captions.bubble", "Subtitles") { sheet = .subtitles }
                quickAction("slider.horizontal.below.rectangle", "Sync") { sheet = .sync }
                Spacer()
                quickAction("rotate.right", "Rotate") { OrientationManager.rotate(); scheduleHide() }
                speedQuick
                quickAction(model.aspect.icon, model.aspect.label) { model.cycleAspect(); scheduleHide() }
            }
        }
        .foregroundStyle(.white)
    }

    private var displayElapsed: String {
        if let f = seekPreview { return VLCPlayerModel.clock(Double(f) * model.totalSeconds) }
        return model.elapsed
    }

    /// Playback speed as a bottom-right quick action (menu on tap).
    private var speedQuick: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button {
                    model.setRate(Float(r)); scheduleHide()
                } label: {
                    Label(r == 1.0 ? "Normal" : "\(r)×",
                          systemImage: model.rate == Float(r) ? "checkmark" : "")
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "speedometer").font(.system(size: 17))
                Text(model.rate == 1.0 ? "Speed" : "\(model.rate)×").font(.system(size: 11))
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: lock overlay

    private var lockOverlay: some View {
        ZStack {
            if lockRevealed {
                VStack {
                    HStack {
                        Spacer()
                        Button { unlock() } label: {
                            Image(systemName: "lock.fill")
                                .font(.title3)
                                .padding(14)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer()
                }
                .padding()
                .transition(.opacity)
            }
        }
    }

    // MARK: reusable buttons

    private func iconButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system).font(.title3) }
    }
    private func skipButton(system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: system).font(.system(size: 40))
                Text("\(model.skipInterval)").font(.system(size: 12, weight: .bold))
            }
        }
    }
    private func quickAction(_ system: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 17))
                Text(title).font(.system(size: 11))
            }
        }
    }

    private func failureView(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text(text).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
        }
        .padding(24)
    }

    // MARK: sheets

    @ViewBuilder
    private func sheetContent(_ s: PlayerSheet) -> some View {
        switch s {
        case .audio:     audioSheet
        case .subtitles: subtitleSheet
        case .sync:      syncSheet
        }
    }

    private var audioSheet: some View {
        NavigationStack {
            List {
                if model.audioTracks.isEmpty {
                    Text("No audio tracks").foregroundStyle(.secondary)
                }
                ForEach(model.audioTracks) { t in
                    trackRow(t.name, selected: model.currentAudioId == t.id) { model.selectAudio(t.id) }
                }
            }
            .navigationTitle("Audio").navigationBarTitleDisplayMode(.inline)
        }
    }

    private var subtitleSheet: some View {
        NavigationStack {
            List {
                Section("Track") {
                    trackRow("Off", selected: model.currentSubtitleId < 0) { model.selectSubtitle(-1) }
                    ForEach(model.subtitleTracks) { t in
                        trackRow(t.name, selected: model.currentSubtitleId == t.id) { model.selectSubtitle(t.id) }
                    }
                }
                Section("Size") {
                    Picker("Size", selection: $subtitleSize) {
                        Text("Small").tag(16); Text("Medium").tag(24); Text("Large").tag(34)
                    }.pickerStyle(.segmented)
                }
                Section("Colour") {
                    Picker("Colour", selection: $subtitleColor) {
                        Text("White").tag(0xFFFFFF); Text("Yellow").tag(0xFFFF00)
                    }.pickerStyle(.segmented)
                }
            }
            .navigationTitle("Subtitles").navigationBarTitleDisplayMode(.inline)
        }
    }

    private var syncSheet: some View {
        NavigationStack {
            List {
                Section("Subtitle delay") {
                    delayStepper(model.subtitleDelayMs) { model.adjustSubtitleDelay($0) }
                }
                Section("Audio delay") {
                    delayStepper(model.audioDelayMs) { model.adjustAudioDelay($0) }
                }
                Section {
                    Button("Reset", role: .destructive) { model.resetSync() }
                }
            }
            .navigationTitle("A-V Sync").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func trackRow(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(PanuraTheme.accent) }
            }
        }
    }

    private func delayStepper(_ value: Int, _ change: @escaping (Int) -> Void) -> some View {
        HStack {
            Button { change(-50) } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
            Spacer()
            Text("\(value) ms").monospacedDigit()
            Spacer()
            Button { change(50) } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.borderless)
        }
        .font(.title3)
        .tint(PanuraTheme.accent)
    }

    // MARK: actions

    private var pipPossible: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private func togglePiP() {
        if pip == nil, let v = model.drawableView { pip = VLCPiPController(source: v, model: model) }
        pip?.toggle()
        scheduleHide()
    }

    private func close() { model.stop(); pip?.teardown(); dismiss() }

    private func lock() {
        withAnimation { locked = true; showControls = false; lockRevealed = true }
        scheduleHideLock()
    }
    private func unlock() { withAnimation { locked = false; lockRevealed = false; showControls = true }; scheduleHide() }

    // MARK: controls visibility

    private func toggleControls() {
        if locked {
            withAnimation { lockRevealed.toggle() }
            if lockRevealed { scheduleHideLock() }
            return
        }
        withAnimation { showControls.toggle() }
        if showControls { scheduleHide() }
    }
    private func showControlsNow() {
        hideTask?.cancel()
        if !showControls { withAnimation { showControls = true } }
    }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            guard !Task.isCancelled, showControls, seekPreview == nil, model.isPlaying else { return }
            withAnimation { showControls = false }
        }
    }
    private func scheduleHideLock() {
        hideTask?.cancel()
        hideTask = Task {
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard !Task.isCancelled, locked else { return }
            withAnimation { lockRevealed = false }
        }
    }

    // MARK: clamps

    private func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
    private func clamp01f(_ v: Float) -> Float { max(0, min(1, v)) }
}

/// Hosts the libVLC drawable UIView and kicks off playback.
private struct VLCVideoView: UIViewRepresentable {
    @ObservedObject var model: VLCPlayerModel
    let item: MediaItem

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        model.start(item: item, into: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
