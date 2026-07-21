import SwiftUI
import UIKit
import VLCKitSPM

/// Full-screen VLC-based player with an Infuse-style control overlay:
/// play/pause, ±10s, scrubber, audio + subtitle track menus, playback speed.
struct PlayerView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VLCPlayerModel()
    @State private var showControls = true
    @State private var scrubbing = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoView(model: model, item: item)
                .ignoresSafeArea()

            // libVLC adds its own subviews to the drawable UIView and they
            // swallow hit-testing, so the tap target must live ABOVE the video
            // rather than on it — otherwise controls never come back.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if model.buffering {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .onAppear { scheduleHide() }
        .onDisappear { model.stop() }
    }

    // MARK: overlay

    private var controlsOverlay: some View {
        ZStack {
            // Tapping the dimmed backdrop hides the controls again.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            VStack {
                topBar
                Spacer()
                centerTransport
                Spacer()
                bottomBar
            }
            .padding()
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { model.stop(); dismiss() } label: {
                Image(systemName: "xmark").font(.title3.bold())
            }
            Text(item.title).lineLimit(1).font(.headline)
            Spacer()
            speedMenu
            trackMenus
        }
        .foregroundStyle(.white)
    }

    private var centerTransport: some View {
        HStack(spacing: 48) {
            Button { model.skip(-10); scheduleHide() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 34))
            }
            Button { model.togglePlay(); scheduleHide() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 54))
            }
            Button { model.skip(10); scheduleHide() } label: {
                Image(systemName: "goforward.10").font(.system(size: 34))
            }
        }
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text(model.elapsed).font(.caption.monospacedDigit())
            Slider(
                value: Binding(
                    get: { model.position },
                    set: { model.position = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { model.seek(to: model.position) }
                    scheduleHide()
                }
            )
            .tint(PanuraTheme.accent)
            Text(model.remaining).font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button {
                    model.setRate(Float(r)); scheduleHide()
                } label: {
                    Label("\(r == 1.0 ? "Normal" : "\(r)×")",
                          systemImage: model.rate == Float(r) ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "speedometer").font(.title3)
        }
    }

    private var trackMenus: some View {
        Menu {
            if !model.audioTracks.isEmpty {
                Section("Audio") {
                    ForEach(model.audioTracks) { t in
                        Button(t.name) { model.selectAudio(t.id); scheduleHide() }
                    }
                }
            }
            if !model.subtitleTracks.isEmpty {
                Section("Subtitles") {
                    Button("Off") { model.selectSubtitle(-1); scheduleHide() }
                    ForEach(model.subtitleTracks) { t in
                        Button(t.name) { model.selectSubtitle(t.id); scheduleHide() }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble").font(.title3)
        }
    }

    // MARK: controls visibility

    private func toggleControls() {
        withAnimation { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            // `try?` would swallow CancellationError and fall through to the
            // hide below — so a just-cancelled timer would instantly re-hide
            // the controls the user only just tapped to show. Bail explicitly.
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, showControls, !scrubbing, model.isPlaying else { return }
            withAnimation { showControls = false }
        }
    }
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
