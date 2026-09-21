import SwiftUI

/// Remote for a stream playing on the Panura Android TV.
///
/// Every value here comes from the TV's `status` messages rather than from local
/// state — the TV is the source of truth, and a remote that guesses drifts out of
/// sync the moment anything is changed with the TV's own remote.
struct PanuraCastControlView: View {
    @ObservedObject private var cast = PanuraCastManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Position being dragged. While non-nil the slider shows this instead of the
    /// TV's reported position, so incoming status updates don't fight the thumb.
    @State private var scrubbing: Double?

    private var playback: PanuraPlayback { cast.playback }
    private var durationSeconds: Double { Double(playback.durationMs) / 1000 }
    private var positionSeconds: Double { scrubbing ?? Double(playback.positionMs) / 1000 }

    var body: some View {
        NavigationStack {
            List {
                Section { nowPlaying } header: { Text("Playing on TV") }
                if !playback.isLive { Section { scrubber } }
                Section { transport } header: { Text("Controls") }
                Section { volume } header: { Text("Volume") }
                if !playback.audioTracks.isEmpty || !playback.subtitleTracks.isEmpty {
                    Section { tracks } header: { Text("Tracks") }
                }
                if !CastFlow.shared.queue.isEmpty {
                    Section {
                        NavigationLink {
                            CastQueueView()
                        } label: {
                            Label(
                                "Queue · \(CastFlow.shared.queue.count) waiting",
                                systemImage: "list.bullet"
                            )
                        }
                    }
                }

                Section {
                    Button("Stop casting", role: .destructive) {
                        cast.stopStream()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Playing on TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cast.streamTitle.isEmpty ? "Video" : cast.streamTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                CastMark(connected: true).frame(width: 14, height: 14)
                Text(cast.connectedTVName.isEmpty ? "Panura TV" : cast.connectedTVName)
                if !cast.mode.isEmpty {
                    Text("·")
                    // Worth surfacing: in proxy mode the phone is serving every
                    // byte and must stay on the network.
                    Text(cast.mode == "direct" ? "Direct" : "Via this phone")
                }
                if playback.isLive {
                    Text("·"); Text("LIVE").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { positionSeconds },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(durationSeconds, 1),
                onEditingChanged: { editing in
                    guard !editing, let target = scrubbing else { return }
                    cast.seek(toMs: Int64(target * 1000))
                    scrubbing = nil
                }
            )
            .tint(PanuraTheme.accent)
            HStack {
                Text(Self.clock(positionSeconds))
                Spacer()
                Text(Self.clock(durationSeconds))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Spacer()
            Button { cast.seek(byMs: -10_000) } label: {
                Image(systemName: "gobackward.10").font(.title2)
            }
            Button { cast.playPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            Button { cast.seek(byMs: 10_000) } label: {
                Image(systemName: "goforward.10").font(.title2)
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .tint(PanuraTheme.accent)
        .padding(.vertical, 4)
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(playback.volume) },
                    set: { cast.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .tint(PanuraTheme.accent)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tracks: some View {
        if !playback.audioTracks.isEmpty {
            Menu {
                ForEach(playback.audioTracks) { track in
                    Button {
                        cast.selectAudioTrack(track.id)
                    } label: {
                        Label(track.label, systemImage: track.selected ? "checkmark" : "")
                    }
                }
            } label: {
                trackRow("Audio", systemImage: "waveform",
                         value: playback.audioTracks.first { $0.selected }?.label ?? "Default")
            }
        }
        if !playback.subtitleTracks.isEmpty {
            Menu {
                Button { cast.disableSubtitles() } label: {
                    Label("Off", systemImage: playback.subtitleTracks.contains { $0.selected } ? "" : "checkmark")
                }
                ForEach(playback.subtitleTracks) { track in
                    Button {
                        cast.selectSubtitleTrack(track.id)
                    } label: {
                        Label(track.label, systemImage: track.selected ? "checkmark" : "")
                    }
                }
            } label: {
                trackRow("Subtitles", systemImage: "captions.bubble",
                         value: playback.subtitleTracks.first { $0.selected }?.label ?? "Off")
            }
        }
    }

    private func trackRow(_ title: String, systemImage: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
