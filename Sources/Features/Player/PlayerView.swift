import SwiftUI
import UIKit
import AVKit

/// Full-screen player with a Panura-branded control overlay, over either engine
/// — `AVPlayerModel` or `VLCPlayerModel`, chosen by `PlayerScreen`:
/// gesture seeking / brightness / volume, ±skip, aspect zoom, controls-lock,
/// orientation-lock, PiP, audio + subtitle tracks, and A-V sync — plus
/// resume-from-position handled by the model.
/// Optional playlist context so the player's next/previous buttons can advance
/// through a list (local videos, downloads). `load` resolves an item lazily so
/// callers needn't pre-resolve every URL up front.
struct PlayerPlaylist {
    let count: Int
    let startIndex: Int
    let load: (Int) async -> MediaItem?
}

struct PlayerView<Model: PlayerEngine>: View {
    let item: MediaItem
    var playlist: PlayerPlaylist? = nil
    /// Auto's hand-over to VLC: called once, with the playlist position and a
    /// reason, when this player cannot play the current video. While it is set
    /// the error screen never shows — VLC replaces this view instead.
    var onUnsupported: ((Int, String) -> Void)? = nil
    /// On the VLC screen that took over from the Apple player: why it did. Its
    /// outcome is reported once, for the decision on keeping VLC.
    var switchReason: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var fallbackOutcomeReported = false
    @State private var handedOver = false
    @StateObject private var model = Model.makeEngine()

    // Playlist position
    @State private var index = 0

    // Control visibility
    @State private var showControls = true
    @State private var locked = false
    @State private var lockRevealed = false
    /// When the controls are due to go away, and when the lock button is.
    ///
    /// A deadline rather than a pending hide task, because a task has to be
    /// cancelled by whoever interrupts it and then re-armed by whoever finishes
    /// — and a single path that cancels without re-arming leaves the controls up
    /// forever. Scrubbing was exactly that path: the slider cancels the hide
    /// when the drag begins and re-arms it when SwiftUI reports the drag ended,
    /// and that report does not always arrive, because the binding's value is
    /// also being rewritten several times a second by playback. Every
    /// interaction now just pushes the deadline out; one ticker enforces it, and
    /// nothing can switch it off.
    @State private var hideAt: Date?
    @State private var lockHideAt: Date?
    @State private var ticker: Task<Void, Never>?
    /// When the scrub position last moved, by slider or by swipe.
    ///
    /// The controls must not time out from under a finger that is dragging
    /// them, and "is dragging" is exactly the fact SwiftUI is unreliable about.
    /// Movement is not: a scrub that has not moved for a few seconds is over,
    /// however it ended.
    @State private var lastScrubMove: Date?


    // Gesture HUD state
    @State private var seekPreview: Float?          // fraction while horizontal-dragging
    @State private var seekBase: Float = 0
    @State private var isGestureSeeking = false     // true only for the swipe-seek (not the slider)
    @State private var verticalAxis: PlayerZone?    // active vertical gesture: .left=brightness, .right=volume
    @State private var brightnessHUD: CGFloat?
    @State private var brightnessBase: CGFloat = 0
    @State private var volumeHUD: CGFloat?
    @State private var volumeBase: Float = 0
    @State private var speedBoosting = false
    @State private var flashZone: PlayerZone?
    @State private var hudClear: Task<Void, Never>?

    // Sheets
    @State private var panel: PlayerSheet?
    /// Folded state of the subtitle panel's appearance group, kept across
    /// openings: someone who went looking for it once will go looking again.
    @State private var subtitleAppearanceOpen = false

    @AppStorage("subtitle_size") private var subtitleSize = 24
    @AppStorage("subtitle_color") private var subtitleColor = 0xFFFFFF
    @AppStorage("subtitle_background") private var subtitleBackground = false
    @AppStorage("subtitle_bold") private var subtitleBold = false
    @AppStorage("preferred_audio_language") private var preferredAudioLang = ""
    @AppStorage("preferred_subtitle_language") private var preferredSubtitleLang = ""
    // Which gestures are live, and how far a drag has to travel. Off means the
    // player ignores that gesture entirely — see GesturePreferencesView.
    @AppStorage("gesture_seek") private var gestureSeek = true
    @AppStorage("gesture_brightness") private var gestureBrightness = true
    @AppStorage("gesture_volume") private var gestureVolume = true
    @AppStorage("gesture_zoom") private var gestureZoom = true
    @AppStorage("gesture_double_tap") private var gestureDoubleTap = true
    @AppStorage("gesture_long_press") private var gestureLongPress = true
    @AppStorage("gesture_sensitivity") private var gestureSensitivity = 1.0

    /// Pinch zoom. 1 = fit as the aspect mode says; above that the picture is
    /// scaled up, below it shrunk, and `videoPan` says where it sits.
    @State private var videoZoom: CGFloat = 1
    @State private var videoPan: CGSize = .zero
    /// Scale when the current pinch started, so the gesture is relative.
    @State private var zoomBase: CGFloat = 1
    /// Shown while pinching, then faded — the same HUD brightness and volume use.
    @State private var zoomHUD: CGFloat?
    /// True between the first change of a pinch and its end. The HUD cannot
    /// stand in for this: it lingers for a moment after the gesture, and a
    /// second pinch inside that moment would measure from a stale base.
    @State private var pinching = false

    enum PlayerSheet: Int, Identifiable {
        case audio, subtitles
        var id: Int { rawValue }
        var title: String { self == .audio ? "Audio" : "Subtitles" }
    }


    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            EngineVideoView(model: model, item: item)
                // Zoom is applied to the surface rather than to libVLC: the
                // decoder keeps rendering the same frames at the same cost, and
                // a scale on the layer is free and instant. Clipped, so a
                // zoomed picture cannot paint over the controls.
                .scaleEffect(videoZoom)
                .offset(videoPan)
                .clipped()
                .ignoresSafeArea()
            // Subtitles the engine hands over as text rather than drawing into the
            // picture. Above the video, beneath every control, never in the way
            // of a touch; lifted clear of the bottom bar while it shows.
            SubtitleOverlay(text: model.overlaySubtitle, lift: showControls && !locked ? 130 : 0)

            // Mounts the hidden MPVolumeView so SystemVolume can drive it. Needs a
            // non-zero footprint for its UISlider to materialise; kept invisible.
            VolumeHost().frame(width: 1, height: 1).opacity(0.001).allowsHitTesting(false)

            gestureSurface.ignoresSafeArea()

            if let failure = model.failure, onUnsupported == nil {
                failureView(failure)
            } else if isLoading || model.failure != nil {
                // A failure about to be handed to VLC reads as loading, not as
                // an error the user is then told to ignore.
                LoadingRing()
            }

            if locked {
                lockOverlay
            } else if showControls {
                controlsOverlay.transition(.opacity)
            }

            // Above the controls, below the HUD. Not a `.sheet`: see
            // PlayerOptionsPanel for why one covered the video in landscape.
            if let panel, !locked {
                PlayerOptionsPanel(title: panel.title, onClose: { closePanel() }) {
                    panelContent(panel)
                }
                .transition(.opacity)
            }

            // Above the controls so gesture feedback overlaps the middle buttons.
            hudLayer.allowsHitTesting(false)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            index = playlist?.startIndex ?? 0
            OrientationManager.allowAll()
            scheduleHide()
            startTicker()
            PlayerAnalytics.opened(engine: engineName, item: item, switchReason: switchReason)
        }
        .onDisappear {
            ticker?.cancel()
            OrientationManager.reset()
            // The session decides whether this dismissal ends the video. It
            // does not when Picture in Picture has just taken the picture: the
            // engine and its surface stay alive, and the bar above the app bar
            // becomes the way back. `stop()` happens in there, not here.
            _ = PlaybackSession.shared.screenDismissed()
        }
        // PiP starting is the cue to get out of the way — the whole point of it
        // is to use the app while the video plays, and a full-screen player
        // saying "this is in Picture in Picture" is the opposite of that.
        .onChange(of: model.isPictureInPictureActive) { active in
            guard active else { return }
            PlaybackSession.shared.beginPictureInPicture()
            dismiss()
        }
        .onChange(of: subtitleSize) { _ in model.subtitleStyleChanged() }
        .onChange(of: subtitleColor) { _ in model.subtitleStyleChanged() }
        .onChange(of: subtitleBackground) { _ in model.subtitleStyleChanged() }
        .onChange(of: subtitleBold) { _ in model.subtitleStyleChanged() }
        .onChange(of: preferredAudioLang) { _ in model.applyPreferredLanguages() }
        .onChange(of: preferredSubtitleLang) { _ in model.applyPreferredLanguages() }
        .onChange(of: model.videoIsPortrait) { p in
            if let p { OrientationManager.applyVideoOrientation(portrait: p) }
        }
        .onChange(of: model.failure) { failure in
            guard let failure else { return }
            if let onUnsupported {
                guard !handedOver else { return }
                handedOver = true
                onUnsupported(index, failure == AVPlayerModel.unsupportedMessage ? "unsupported" : "failed")
            } else {
                PlayerAnalytics.failed(engine: engineName, item: item)
                reportFallbackOutcome(played: false)
            }
        }
        .onChange(of: model.isPlaying) { playing in
            if playing { reportFallbackOutcome(played: true) }
        }
    }

    // MARK: gesture surface

    private var gestureSurface: some View {
        PlayerGestureSurface(
            onSingleTap: { toggleControls() },
            onDoubleTap: { handleDoubleTap($0) },
            onSeekBegan: {
                guard !locked, gestureSeek else { return }
                seekBase = model.position; seekPreview = model.position
                // Deliberately does NOT reveal the controls — a seek gesture only
                // shows its own HUD; controls stay in whatever state they were.
                isGestureSeeking = true
            },
            onSeekChanged: { dx in
                guard !locked, seekPreview != nil else { return }
                let total = model.totalSeconds
                guard total > 0 else { return }
                // Time-based, not fraction-based: a full-width swipe moves ~90s
                // regardless of length (it used to jump the whole video).
                let target = Double(seekBase) * total + Double(dx) * 90 * gestureSensitivity
                seekPreview = clamp01f(Float(target / total))
                lastScrubMove = Date()
            },
            onSeekEnded: {
                guard !locked, let f = seekPreview else { return }
                model.seek(to: f); seekPreview = nil; isGestureSeeking = false
                lastScrubMove = nil; scheduleHide()
            },
            onVerticalBegan: { beginVertical($0) },
            onVerticalChanged: { changeVertical($0) },
            onVerticalEnded: { endVertical() },
            onLongPressBegan: { beginBoost() },
            onLongPressEnded: { endBoost() },
            onPinchChanged: { scale in changeZoom(scale) },
            onPinchEnded: { endZoom() },
            onTwoFingerPan: { movePicture(by: $0) }
        )
    }

    // MARK: pinch zoom

    /// Scales the video surface between 25% and 4×, the same range as Android.
    ///
    /// A cap, because past about 4× a 1080p frame is showing its own pixels and
    /// the gesture stops being useful. Below fit the picture shrinks into the
    /// screen; a pinch back out, or the aspect button, restores it. Near 100%
    /// it snaps, since landing on exactly fit by hand is otherwise luck.
    private func changeZoom(_ scale: CGFloat) {
        guard !locked, gestureZoom else { return }
        if !pinching { pinching = true; zoomBase = videoZoom; hudClear?.cancel() }
        var next = min(max(zoomBase * scale, 0.25), 4)
        if abs(next - 1) < 0.04 { next = 1 }
        videoZoom = next
        zoomHUD = next
        if next == 1 { videoPan = .zero }   // back to fit: nothing left to look around
        else { videoPan = clampPan(videoPan, zoom: next) }
    }

    /// A new aspect mode starts from fit, as on Android.
    private func resetZoom() {
        videoZoom = 1
        videoPan = .zero
    }

    private func endZoom() {
        pinching = false
        hudClear?.cancel()
        hudClear = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation { zoomHUD = nil }
        }
    }

    /// Two-finger drag moves a zoomed or shrunk picture. Ignored at fit, where
    /// there is nowhere for it to go.
    private func movePicture(by delta: CGSize) {
        guard !locked, gestureZoom, videoZoom != 1 else { return }
        videoPan = clampPan(
            CGSize(width: videoPan.width + delta.width, height: videoPan.height + delta.height),
            zoom: videoZoom
        )
    }

    /// Zoomed in, the picture keeps covering the screen: you can never drag
    /// past its edge into black. Shrunk, it stays wholly on screen. Either way
    /// the slack is half the size difference, per axis.
    private func clampPan(_ pan: CGSize, zoom: CGFloat) -> CGSize {
        let screen = UIScreen.main.bounds.size
        let slackX = abs(screen.width * (zoom - 1) / 2)
        let slackY = abs(screen.height * (zoom - 1) / 2)
        return CGSize(
            width: min(max(pan.width, -slackX), slackX),
            height: min(max(pan.height, -slackY), slackY)
        )
    }

    private func handleDoubleTap(_ zone: PlayerZone) {
        guard !locked else { toggleControls(); return }
        // Off, a double tap is two single taps: show the controls, hide them
        // again — which is what it would have done before this gesture existed.
        guard gestureDoubleTap else { toggleControls(); return }
        switch zone {
        case .left:  model.skipBackward(); flashSkip(.left)
        case .right: model.skipForward();  flashSkip(.right)
        case .center: model.togglePlay()
        }
        scheduleHide()
    }

    private func beginVertical(_ zone: PlayerZone) {
        guard !locked else { return }
        guard zone == .left ? gestureBrightness : gestureVolume else { return }
        // Cancel any pending hide from a previous swipe — otherwise it fires
        // mid-gesture and the HUD vanishes under the finger.
        hudClear?.cancel()
        verticalAxis = zone
        if zone == .left {
            brightnessBase = ScreenBrightness.level; brightnessHUD = brightnessBase; volumeHUD = nil
        } else {
            volumeBase = SystemVolume.shared.level; volumeHUD = CGFloat(volumeBase); brightnessHUD = nil
        }
    }
    private func changeVertical(_ d: CGFloat) {
        // Drive off the tracked axis, NOT the HUD's presence — a stale clear
        // could nil the HUD and freeze the gesture.
        guard !locked, let axis = verticalAxis else { return }
        let travel = d * CGFloat(gestureSensitivity)
        if axis == .left {
            let b = clamp01(brightnessBase + travel); ScreenBrightness.set(b); brightnessHUD = b
        } else {
            let v = Float(clamp01(CGFloat(volumeBase) + travel)); SystemVolume.shared.set(v); volumeHUD = CGFloat(v)
        }
    }
    private func endVertical() {
        verticalAxis = nil
        hudClear?.cancel()
        hudClear = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard verticalAxis == nil else { return }   // a new swipe started; keep it
            withAnimation { brightnessHUD = nil; volumeHUD = nil }
        }
    }

    private func beginBoost() {
        guard !locked, gestureLongPress, model.isPlaying else { return }
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
            if let zoom = zoomHUD {
                Label(String(format: "%.0f%%", zoom * 100), systemImage: "magnifyingglass")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.4), in: Capsule())
                    .foregroundStyle(.white)
            }
            if speedBoosting {
                Label("2×", systemImage: "forward.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.4), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 44)
            }
            // Only for the swipe-seek gesture — the slider shows its own position,
            // and this HUD reliably clears when the gesture ends.
            if isGestureSeeking, let f = seekPreview { seekHUD(f) }
            // The HUD shows on the OPPOSITE edge from the touch: brightness (left
            // touch) → right, volume (right touch) → left. Mirrors the Android player.
            if let b = brightnessHUD {
                verticalHUD(icon: "sun.max.fill", value: b)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 28)
            }
            if let v = volumeHUD {
                verticalHUD(icon: v <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill", value: v)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 28)
            }
            if let z = flashZone { skipFlash(z) }
        }
    }

    private func seekHUD(_ f: Float) -> some View {
        let total = model.totalSeconds
        let target = Double(f) * total
        let delta = target - model.elapsedSeconds
        return VStack(spacing: 4) {
            Text(PlayerClock.format(target)).font(.title2.monospacedDigit().bold())
            Text("\(delta >= 0 ? "+" : "-")\(PlayerClock.format(abs(delta)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Vertical capsule bar (Android VerticalProgressView): fill from the bottom,
    /// percentage on top, icon at the bottom.
    private func verticalHUD(icon: String, value: CGFloat) -> some View {
        let v = max(0, min(1, value))
        let pct = Int((v * 100).rounded())
        let barHeight: CGFloat = 190
        return ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
            PanuraTheme.accent.opacity(0.75).frame(height: barHeight * v)
            VStack {
                Text("\(pct)").font(.callout.monospacedDigit().weight(.semibold))
                Spacer()
                Image(systemName: icon).font(.system(size: 20))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 16)
        }
        .frame(width: 44, height: barHeight)
        .clipShape(Capsule())
    }

    /// Android-style double-tap seek indicator: a D-shaped white wash on the edge
    /// with animated chevrons and the skip amount below.
    private func skipFlash(_ zone: PlayerZone) -> some View {
        let forward = zone == .right
        return GeometryReader { geo in
            ZStack {
                EdgeOvalShape(rightSide: forward).fill(Color.white.opacity(0.2))
                SkipFlashContent(forward: forward, seconds: model.skipInterval)
            }
            .frame(width: geo.size.width * 0.42, height: geo.size.height)
            .position(
                x: forward ? geo.size.width - geo.size.width * 0.21 : geo.size.width * 0.21,
                y: geo.size.height / 2
            )
        }
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

            // Top bar pinned to the top; bottom bar hugs the very bottom edge
            // (no extra bottom inset) so it sits low, matching Android.
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            // Transport on the TRUE screen center, independent of bar heights.
            // Hidden only during a swipe-seek (not a slider drag) so the seek HUD
            // reads clearly and the buttons reliably return when the finger lifts.
            if model.failure == nil {
                centerTransport.opacity(isGestureSeeking ? 0 : 1)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            iconButton("xmark") { close() }
                .background(Color.black.opacity(0.3), in: Circle())
            Text(model.displayTitle.isEmpty ? item.title : model.displayTitle)
                .lineLimit(1).font(.headline)
            Spacer()
            HStack(spacing: 4) {
                if model.supportsAirPlay {
                    AirPlayButton().frame(width: 40, height: 40)
                }
                if model.supportsPictureInPicture {
                    iconButton(model.isPictureInPictureActive ? "pip.exit" : "pip.enter") {
                        model.togglePictureInPicture(); scheduleHide()
                    }
                }
                iconButton("lock.fill") { lock() }
            }
            .background(Color.black.opacity(0.3), in: Capsule())
        }
        .foregroundStyle(.white)
    }

    /// Buffering, and not because a hold-to-speed gesture outran the buffer —
    /// that one is the user's own doing and shows its own badge.
    private var isLoading: Bool { model.buffering && !speedBoosting && model.failure == nil }

    private var centerTransport: some View {
        HStack(spacing: 40) {
            if playlist != nil {
                circleTransport("backward.end.fill", size: 52, icon: 20, enabled: canPrevious) { goToPrevious() }
            }
            // The spinner occupies this spot while the video is opening, so the
            // play button gives it up rather than sitting on top of it. Its
            // width is held, or the skip buttons would jump inwards and back
            // every time the stream rebuffers.
            if isLoading {
                Color.clear.frame(width: 70, height: 70)
            } else {
                circleTransport(model.isPlaying ? "pause.fill" : "play.fill", size: 70, icon: 32) {
                    model.togglePlay(); scheduleHide()
                }
            }
            if playlist != nil {
                circleTransport("forward.end.fill", size: 52, icon: 20, enabled: canNext) { goToNext() }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(displayElapsed).font(.caption.monospacedDigit())
                Slider(
                    value: Binding(
                        get: { Double(seekPreview ?? model.position) },
                        // Each increment stamps the clock rather than
                        // cancelling anything. That, not the editing-ended
                        // callback, is what guarantees the controls eventually
                        // go: the last stamp lands as the finger lifts.
                        set: { seekPreview = Float($0); lastScrubMove = Date() }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing { showControlsNow() }
                        else {
                            if let f = seekPreview { model.seek(to: f) }
                            seekPreview = nil; lastScrubMove = nil; scheduleHide()
                        }
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
            .foregroundStyle(.white)

            // The roomiest button size that fits, tried in order. The last,
            // glyphs only, fits any phone — so the row can never be wider than
            // the screen and drag the seek bar and top bar out with it.
            ViewThatFits(in: .horizontal) {
                ForEach(QuickMetrics.steps, id: \.self) { size in
                    quickRow.environment(\.quickButton, size)
                }
            }
            .foregroundStyle(.white)
        }
    }

    private var quickRow: some View {
        HStack(spacing: 0) {
            // Bottom-left group
            HStack(spacing: QuickMetrics.buttonGap) {
                quickAction("waveform", "Audio") { openPanel(.audio) }
                quickAction("captions.bubble", "Subtitles") { openPanel(.subtitles) }
                if !model.qualities.isEmpty { qualityQuick }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.black.opacity(0.3), in: Capsule())

            Spacer(minLength: QuickMetrics.groupGap)

            // Bottom-right group
            HStack(spacing: QuickMetrics.buttonGap) {
                quickAction("rotate.right", "Rotate") { OrientationManager.rotate(); scheduleHide() }
                sleepQuick
                speedQuick
                aspectAction
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.black.opacity(0.3), in: Capsule())
        }
    }

    private func circleTransport(
        _ system: String, size: CGFloat, icon: CGFloat, enabled: Bool = true,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: icon))
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.3), in: Circle())
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .foregroundStyle(.white)
    }

    private var displayElapsed: String {
        if let f = seekPreview { return PlayerClock.format(Double(f) * model.totalSeconds) }
        return model.elapsed
    }

    /// Aspect cycle button with a fixed-width label so "Stretch" doesn't widen
    /// the bottom-right group (the icon + text both swap per mode).
    private var aspectAction: some View {
        Button {
            model.cycleAspect(); resetZoom(); scheduleHide()
        } label: {
            quickActionLabel(model.aspect.icon, model.aspect.label)
        }
        .foregroundStyle(.white)
    }

    /// Quality as a menu quick action, same shape as `speedQuick` — the label
    /// carries the current selection, so the choice is readable without opening
    /// anything. Each row also shows the rough size at that bitrate.
    private var qualityQuick: some View {
        Menu {
            ForEach(model.qualities) { q in
                Button {
                    model.selectQuality(q); scheduleHide()
                } label: {
                    // Built as an explicit String: a ternary of interpolations
                    // makes Label's LocalizedStringKey overload a candidate, and
                    // the size would render as a literal key.
                    let size = q.sizeEstimate(durationSeconds: model.totalSeconds)
                    let title: String = size.isEmpty ? q.label : q.label + "  ·  " + size
                    Label(title, systemImage: model.currentQualityId == q.id ? "checkmark" : "")
                }
            }
        } label: {
            quickActionLabel("rectangle.stack", currentQualityLabel)
        }
        .foregroundStyle(.white)
    }

    /// "Quality" while on Auto, otherwise the chosen rendition ("1080p").
    private var currentQualityLabel: String {
        guard let current = model.qualities.first(where: { $0.id == model.currentQualityId }),
              current.id != PlayerQuality.auto.id
        else { return "Quality" }
        return current.label
    }

    /// Playback speed as a bottom-right quick action (menu on tap).
    private var speedQuick: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button {
                    model.setRate(Float(r)); scheduleHide()
                } label: {
                    Label(r == 1.0 ? "Normal" : Self.speedText(r),
                          systemImage: model.rate == Float(r) ? "checkmark" : "")
                }
            }
        } label: {
            quickActionLabel(
                "speedometer",
                model.rate == 1.0 ? "Speed" : Self.speedText(Double(model.rate))
            )
        }
        .foregroundStyle(.white)
    }

    /// Sleep timer, beside the speed control. Its label counts down while one
    /// is running, because a timer you cannot see the end of is one you will
    /// not trust to be running at all.
    private var sleepQuick: some View {
        Menu {
            if model.sleepRemaining != nil {
                Button(role: .destructive) {
                    model.cancelSleepTimer(); scheduleHide()
                } label: { Label("Cancel timer", systemImage: "xmark") }
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button {
                    model.startSleepTimer(minutes: minutes); scheduleHide()
                } label: { Text("\(minutes) minutes") }
            }
        } label: {
            quickActionLabel(
                model.sleepRemaining == nil ? "moon" : "moon.fill",
                model.sleepLabel ?? "Sleep"
            )
        }
        .foregroundStyle(model.sleepRemaining == nil ? .white : PanuraTheme.accent)
    }

    /// "%g" trims trailing zeros: 1.5 → "1.5×", 2 → "2×", 0.75 → "0.75×".
    /// Interpolating a Float straight into Text goes via LocalizedStringKey and
    /// prints "1.500000×", so format it to a plain String first.
    private static func speedText(_ r: Double) -> String { String(format: "%g×", r) }

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
        Button(action: action) {
            Image(systemName: system).font(.title3).frame(width: 40, height: 40)
        }
    }

    private func quickAction(_ system: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            quickActionLabel(system, title)
        }
    }

    private func quickActionLabel(_ system: String, _ title: String) -> some View {
        QuickActionLabel(system: system, title: title)
    }

    private func failureView(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text(text).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
            // Said out loud rather than deleted silently, and only when
            // something was actually removed.
            if model.resumeEntryRemoved {
                Text("This link is no longer available, so it has been removed from Continue Watching.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    // MARK: option panels

    @ViewBuilder
    private func panelContent(_ s: PlayerSheet) -> some View {
        switch s {
        case .audio:     audioPanel
        case .subtitles: subtitlePanel
        }
    }

    private func openPanel(_ which: PlayerSheet) {
        withAnimation(.easeOut(duration: 0.18)) { panel = which }
    }

    /// Closes the panel and restarts the controls' hide clock, which was held
    /// open for as long as one was up.
    private func closePanel() {
        withAnimation(.easeOut(duration: 0.18)) { panel = nil }
        scheduleHide()
    }

    private var audioPanel: some View {
        Group {
            PanelHeader("Track")
            if model.audioTracks.isEmpty {
                Text("No audio tracks")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 9)
            }
            ForEach(model.audioTracks) { t in
                PanelChoiceRow(title: t.name, selected: model.currentAudioId == t.id) {
                    model.selectAudio(t.id)
                }
            }

            if model.supportsAudioDelay {
                PanelDivider()
                PanelStepperRow(
                    title: "Delay",
                    value: "\(model.audioDelayMs) ms"
                ) { model.adjustAudioDelay($0) }
            }

            PanelDivider()
            HStack {
                Text("Preferred language").font(.callout).foregroundStyle(.white)
                Spacer(minLength: 8)
                languagePicker(selection: $preferredAudioLang)
            }
            .padding(.vertical, 5)

            if model.supportsAudioBoost {
                PanelDivider()
                PanelHeader("Volume boost")
                boostRow
            }
        }
    }

    private var subtitlePanel: some View {
        Group {
            PanelHeader("Track")
            PanelChoiceRow(title: "Off", selected: model.currentSubtitleId < 0) {
                model.selectSubtitle(-1)
            }
            ForEach(model.subtitleTracks) { t in
                PanelChoiceRow(title: t.name, selected: model.currentSubtitleId == t.id) {
                    model.selectSubtitle(t.id)
                }
            }

            if model.supportsSubtitleDelay {
                PanelDivider()
                PanelStepperRow(
                    title: "Delay",
                    value: "\(model.subtitleDelayMs) ms"
                ) { model.adjustSubtitleDelay($0) }
            }

            PanelDivider()
            HStack {
                Text("Preferred language").font(.callout).foregroundStyle(.white)
                Spacer(minLength: 8)
                languagePicker(selection: $preferredSubtitleLang)
            }
            .padding(.vertical, 5)

            PanelDivider()
            // Folded: picking a track is why this panel gets opened, and that
            // list was underneath a screenful of appearance controls someone
            // sets once a year.
            PanelDisclosure(title: "Appearance", open: $subtitleAppearanceOpen) {
                PanelHeader("Size")
                Picker("Size", selection: $subtitleSize) {
                    Text("Small").tag(16); Text("Medium").tag(24); Text("Large").tag(34)
                }
                .pickerStyle(.segmented)

                PanelHeader("Colour")
                Picker("Colour", selection: $subtitleColor) {
                    Text("White").tag(0xFFFFFF); Text("Yellow").tag(0xFFFF00)
                }
                .pickerStyle(.segmented)

                PanelToggleRow(title: "Bold", isOn: $subtitleBold)
                PanelToggleRow(title: "Background", isOn: $subtitleBackground)

                Text("Font, outline and text encoding are in Settings \u{2192} Subtitles.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 6)
            }
        }
    }


    private func languagePicker(selection: Binding<String>) -> some View {
        Picker("Language", selection: selection) {
            Text("Off").tag("")
            ForEach(PlayerLanguages.common, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .tint(PanuraTheme.accent)
    }

    private var boostRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { Double(model.audioBoost) },
                               set: { model.setAudioBoost(Int($0)) }),
                in: 100...200, step: 10
            )
            .tint(PanuraTheme.accent)
            Text("\(model.audioBoost)%").monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: actions

    private func close() { model.stop(); dismiss() }

    private var engineName: String { Model.self == VLCPlayerModel.self ? "vlc" : "av" }

    private func reportFallbackOutcome(played: Bool) {
        guard let switchReason, !fallbackOutcomeReported else { return }
        fallbackOutcomeReported = true
        PlayerAnalytics.switchResult(played: played, item: item, reason: switchReason)
    }

    // MARK: playlist next / previous

    private var canPrevious: Bool { playlist != nil && index > 0 }
    private var canNext: Bool { if let pl = playlist { return index + 1 < pl.count }; return false }

    private func goToPrevious() { advance(to: index - 1) }
    private func goToNext() { advance(to: index + 1) }

    private func advance(to newIndex: Int) {
        guard let pl = playlist, newIndex >= 0, newIndex < pl.count else { return }
        scheduleHide()
        Task {
            if let next = await pl.load(newIndex) {
                index = newIndex
                model.play(item: next)
            }
        }
    }

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
        if !showControls { withAnimation { showControls = true } }
        scheduleHide()
    }

    /// Push the controls' disappearance out. Called by everything the user can
    /// touch, and by the ticker itself while a scrub or a panel holds them open.
    private func scheduleHide() {
        #if DEBUG
        // The screenshot run photographs the player, and a player whose controls
        // have timed out is a screenshot of a video. nil means "no hide due".
        if ScreenshotMode.isActive { hideAt = nil; return }
        #endif
        hideAt = Date().addingTimeInterval(PlayerTiming.autoHide)
    }

    private func scheduleHideLock() { lockHideAt = Date().addingTimeInterval(PlayerTiming.autoHideLock) }

    /// One timer for the lifetime of the player, checking both deadlines.
    ///
    /// A quarter-second beat: fine enough that the controls go at the moment
    /// they are due, coarse enough to cost nothing next to decoding video.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                let now = Date()
                // An open panel is the user reading a track list, not idling; and the
                // controls must still be there when it closes.
                if panel != nil { scheduleHide(); continue }
                if let m = lastScrubMove, now.timeIntervalSince(m) < 3 { scheduleHide(); continue }
                if locked {
                    if lockRevealed, let d = lockHideAt, now >= d {
                        withAnimation { lockRevealed = false }
                        lockHideAt = nil
                    }
                    continue
                }
                if showControls, let d = hideAt, now >= d {
                    withAnimation { showControls = false }
                    hideAt = nil
                }
            }
        }
    }

    // MARK: clamps

    private func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
    private func clamp01f(_ v: Float) -> Float { max(0, min(1, v)) }
}

/// D-shaped wash on the screen edge for the double-tap seek indicator: flat on
/// the outer edge, bulging inward. Mirrors Android's Left/RightSideOvalShape.
private struct EdgeOvalShape: Shape {
    let rightSide: Bool
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        if rightSide {
            p.move(to: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w * 0.1, y: 0))
            p.addCurve(to: CGPoint(x: w * 0.1, y: h),
                       control1: CGPoint(x: -w * 0.1, y: h / 2),
                       control2: CGPoint(x: -w * 0.1, y: h / 2))
        } else {
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w * 0.9, y: 0))
            p.addCurve(to: CGPoint(x: w * 0.9, y: h),
                       control1: CGPoint(x: w * 1.1, y: h / 2),
                       control2: CGPoint(x: w * 1.1, y: h / 2))
            p.addLine(to: CGPoint(x: 0, y: h))
        }
        p.closeSubpath()
        return p
    }
}

/// Three chevrons that fade in sequence, over the skip amount — the animated
/// heart of the double-tap indicator.
private struct SkipFlashContent: View {
    let forward: Bool
    let seconds: Int
    @State private var animating = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: "play.fill")
                        .rotationEffect(.degrees(forward ? 0 : 180))
                        .font(.system(size: 15))
                        .opacity(animating ? 1 : 0.25)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                                .delay(Double(forward ? i : 2 - i) * 0.15),
                            value: animating
                        )
                }
            }
            Text("\(seconds) seconds").font(.caption)
        }
        .foregroundStyle(.white)
        .onAppear { animating = true }
    }
}


/// Android's circular progress indicator, drawn.
///
/// `ProgressView()` is iOS's spinner — a ring of tapering spokes — and it reads
/// as a system alert rather than as this app. Material's is one accent arc
/// sweeping a track: a quarter-circle that rotates at a constant speed while its
/// length breathes, which is what makes it look like it is making progress
/// rather than merely spinning.
private struct LoadingRing: View {
    var size: CGFloat = 44
    var lineWidth: CGFloat = 3.5

    @State private var rotation: Double = 0
    @State private var trim: CGFloat = 0.08

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: trim)
                .stroke(
                    PanuraTheme.accent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: size, height: size)
        .onAppear {
            // Two animations rather than one: a constant spin, and a sweep that
            // grows and shrinks against it. Together they give the arc its
            // varying speed — one animation can only ever produce a metronome.
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                trim = 0.72
            }
        }
    }
}

// MARK: - Constants
//
// File scope because PlayerView is generic, and Swift allows no static stored
// properties in a generic type or in anything nested inside one.

private enum PlayerTiming {
    static let autoHide: TimeInterval = 4
    static let autoHideLock: TimeInterval = 3
}

/// Common languages offered for the preferred-audio/subtitle pickers. Matched
/// (case-insensitively) against the engine's track names, so it's best-effort.
private enum PlayerLanguages {
    static let common = [
        "English", "Hindi", "Tamil", "Telugu", "Malayalam", "Kannada", "Marathi",
        "Bengali", "Spanish", "French", "German", "Italian", "Arabic", "Japanese",
        "Korean", "Chinese", "Russian", "Portuguese", "Turkish",
    ]
}

/// Every control in the two capsules is the same width, whatever its
/// caption says at the time.
///
/// Four change their own label as they are used — Speed becomes "1.5×", Fit
/// becomes "Fill", Quality becomes "1080p", Sleep becomes "42m" — and a row
/// of self-sizing buttons re-spaces itself every time one of them does,
/// with the widest caption shoving its neighbours apart. So they share one
/// width, chosen by `ViewThatFits` from `steps`.
///
/// That replaced a width computed from a measured screen. The arithmetic
/// could not see the spacing SwiftUI adds around a Spacer, so seven buttons
/// came out about 20pt too wide, and before the first measurement they were
/// full size; either way the row pushed the whole overlay past both edges.
/// Letting layout try each size cannot be wrong about what fits.
private enum QuickMetrics {
    static let steps: [QuickButtonSize] = [
        // Roomy enough for "Subtitles" at full size.
        QuickButtonSize(width: 58, captions: true),
        QuickButtonSize(width: 52, captions: true),
        // Below this a caption is squeezed past legibility.
        QuickButtonSize(width: 46, captions: true),
        // Glyphs carry the row.
        QuickButtonSize(width: 40, captions: false),
        // Nothing useful is left of a 17pt glyph's tap target below this.
        QuickButtonSize(width: 34, captions: false),
    ]
    /// Between the two capsules, at their closest.
    static let groupGap: CGFloat = 12
    static let buttonGap: CGFloat = 4
}

struct QuickButtonSize: Hashable {
    let width: CGFloat
    let captions: Bool
}

private struct QuickButtonSizeKey: EnvironmentKey {
    static let defaultValue = QuickMetrics.steps[0]
}

extension EnvironmentValues {
    var quickButton: QuickButtonSize {
        get { self[QuickButtonSizeKey.self] }
        set { self[QuickButtonSizeKey.self] = newValue }
    }
}

/// The stack inside every quick action: glyph over caption, at the width the
/// row settled on, one line of caption that shrinks rather than wrapping.
private struct QuickActionLabel: View {
    let system: String
    let title: String
    @Environment(\.quickButton) private var size

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 17))
            if size.captions {
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: size.width)
        // Without this the glyph-only row has a smaller tap target than the
        // captioned one, for no reason the user can see.
        .frame(height: 38)
    }
}
