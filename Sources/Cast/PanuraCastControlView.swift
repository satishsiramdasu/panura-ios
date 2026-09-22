import SwiftUI

/// Remote for a stream playing on the Panura Android TV.
///
/// Every value here comes from the TV's `status` messages rather than from local
/// state — the TV is the source of truth, and a remote that guesses drifts out of
/// sync the moment anything is changed with the TV's own remote.
///
/// Laid out as a remote, not as a settings screen. It was a grouped `List` with
/// a header over every row — "Playing on TV", "Controls", "Volume", "Tracks" —
/// which is the shape iOS gives a page of preferences, and it read as one: four
/// captions labelling four things that need no labelling, and the play button
/// the same size as a table row. A remote needs one thing far bigger than the
/// rest, which is the shape here: the television and what is on it, then the
/// scrubber, then transport, and everything else small.
struct PanuraCastControlView: View {
    @ObservedObject private var cast = PanuraCastManager.shared
    @ObservedObject private var flow = CastFlow.shared
    @Environment(\.dismiss) private var dismiss

    /// Position being dragged. While non-nil the slider shows this instead of the
    /// TV's reported position, so incoming status updates don't fight the thumb.
    @State private var scrubbing: Double?
    @State private var showQueue = false

    private var playback: PanuraPlayback { cast.playback }
    private var durationSeconds: Double { Double(playback.durationMs) / 1000 }
    private var positionSeconds: Double { scrubbing ?? Double(playback.positionMs) / 1000 }

    var body: some View {
        VStack(spacing: 0) {
            CastControlBar(
                queueCount: flow.queue.count,
                onQueue: { showQueue = true },
                onDone: { dismiss() }
            )

            ScrollView {
                VStack(spacing: 26) {
                    CastHero(
                        title: cast.streamTitle.isEmpty ? "Video" : cast.streamTitle,
                        device: cast.connectedTVName.isEmpty ? "Panura TV" : cast.connectedTVName,
                        note: modeNote,
                        isLive: playback.isLive
                    )
                    if !playback.isLive { scrubber }
                    transport
                    volume
                    tracks
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            CastStopButton(title: "Stop casting") {
                cast.stopStream()
                dismiss()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
        }
        .background(PanuraTheme.background)
        .sheet(isPresented: $showQueue) {
            NavigationStack { CastQueueView() }
        }
    }

    /// Worth surfacing: in proxy mode the phone is serving every byte and must
    /// stay on the network.
    private var modeNote: String? {
        guard !cast.mode.isEmpty else { return nil }
        return cast.mode == "direct" ? "Direct" : "Via this phone"
    }

    // MARK: scrubber

    /// The two times sit at the ends of the bar they describe rather than in a
    /// row of their own under it.
    private var scrubber: some View {
        VStack(spacing: 6) {
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
            .font(.caption.monospacedDigit())
            .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
    }

    // MARK: transport

    /// One big button and two small ones. Play/pause is what a remote is for and
    /// it is sized like it; the skips are corrections.
    private var transport: some View {
        HStack(spacing: 34) {
            CastGlyphButton(
                system: "gobackward.10", label: "Back ten seconds"
            ) { cast.seek(byMs: -10_000) }

            Button { cast.playPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(PanuraTheme.onAccent)
                    .frame(width: 74, height: 74)
                    .background(Circle().fill(PanuraTheme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            CastGlyphButton(
                system: "goforward.10", label: "Forward ten seconds"
            ) { cast.seek(byMs: 10_000) }
        }
        .padding(.vertical, 2)
    }

    // MARK: volume

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            Slider(
                value: Binding(
                    get: { Double(playback.volume) },
                    set: { cast.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .tint(PanuraTheme.accent)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(PanuraTheme.onSurfaceVariant)
    }

    // MARK: tracks

    /// Two pills rather than two table rows, and only for what the stream
    /// actually carries — a file with one audio track has nothing to choose
    /// between, and a row that always says "Default" teaches people to stop
    /// reading this part of the screen.
    @ViewBuilder
    private var tracks: some View {
        if !playback.audioTracks.isEmpty || !playback.subtitleTracks.isEmpty {
            HStack(spacing: 10) {
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
                        trackPill(
                            "Audio", systemImage: "waveform",
                            value: playback.audioTracks.first { $0.selected }?.label ?? "Default"
                        )
                    }
                }
                if !playback.subtitleTracks.isEmpty {
                    Menu {
                        Button { cast.disableSubtitles() } label: {
                            Label(
                                "Off",
                                systemImage: playback.subtitleTracks.contains { $0.selected } ? "" : "checkmark"
                            )
                        }
                        ForEach(playback.subtitleTracks) { track in
                            Button {
                                cast.selectSubtitleTrack(track.id)
                            } label: {
                                Label(track.label, systemImage: track.selected ? "checkmark" : "")
                            }
                        }
                    } label: {
                        trackPill(
                            "Subtitles", systemImage: "captions.bubble",
                            value: playback.subtitleTracks.first { $0.selected }?.label ?? "Off"
                        )
                    }
                }
            }
        }
    }

    private func trackPill(_ title: String, systemImage: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(PanuraTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                Text(value)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanuraTheme.surfaceVariant)
        )
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

// MARK: - the parts both remotes share

/// Done · what this screen is · the queue.
///
/// The queue button carries its count and is simply absent when nothing is
/// waiting: a control for an empty list is a control that has to be explained.
struct CastControlBar: View {
    var queueCount: Int = 0
    var onQueue: () -> Void = {}
    let onDone: () -> Void

    var body: some View {
        HStack {
            Button(action: onDone) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(PanuraTheme.surfaceVariant))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")

            Spacer()
            Text("Playing on TV")
                .font(.subheadline.weight(.semibold))
            Spacer()

            if queueCount > 0 {
                Button(action: onQueue) {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(queueCount)").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(PanuraTheme.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Capsule().fill(PanuraTheme.accentSoft.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Queue, \(queueCount) waiting")
            } else {
                Color.clear.frame(width: 38, height: 38)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// The television, and what is on it.
///
/// A still would be a lie — the video is on the TV and this phone has no frame
/// of it — so the space says the two true things instead, in the order they
/// matter: what is playing, and where.
struct CastHero: View {
    let title: String
    let device: String
    var note: String?
    var isLive = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(PanuraTheme.surfaceVariant)
                    .frame(width: 128, height: 128)
                Image(systemName: "tv.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(PanuraTheme.accent)
            }
            .padding(.top, 6)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    CastMark(connected: true).frame(width: 13, height: 13)
                    Text(device)
                    if let note {
                        Text("·")
                        Text(note)
                    }
                    if isLive {
                        Text("·")
                        Text("LIVE").foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A transport glyph that is not the play button.
struct CastGlyphButton: View {
    let system: String
    var size: CGFloat = 26
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Stop, at the foot of the screen, red and the width of it.
///
/// It was a `destructive` row in a table — red text on the same grey as
/// everything else, in a list where every other row did something small and
/// reversible. Ending what is on the television is the one irreversible thing
/// this screen does, and it is what people come back to the screen for, so it
/// is the one control that never scrolls away.
struct CastStopButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: 0xC0392B))
                )
        }
        .buttonStyle(.plain)
    }
}
