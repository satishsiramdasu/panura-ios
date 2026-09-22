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

    private var playback: PanuraPlayback { cast.playback }
    private var durationSeconds: Double { Double(playback.durationMs) / 1000 }
    private var positionSeconds: Double { scrubbing ?? Double(playback.positionMs) / 1000 }

    var body: some View {
        VStack(spacing: 0) {
            CastControlBar(
                device: cast.connectedTVName.isEmpty ? "TV" : cast.connectedTVName,
                note: modeNote,
                onDone: { dismiss() }
            )

            ScrollView {
                VStack(spacing: 26) {
                    CastHero(
                        title: cast.streamTitle.isEmpty ? "Video" : cast.streamTitle,
                        isLive: playback.isLive,
                        posterURL: flow.nowPlaying?.posterURL,
                        posterImage: flow.nowPlaying?.posterImage
                    )
                    if !playback.isLive { scrubber }
                    transport
                    // Audio, subtitles and volume in one row: three controls
                    // that each change one thing about the sound or the words,
                    // and none of which needs a row of its own.
                    secondaryControls
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }

            // What is lined up sits under what is playing, on the same screen.
            // It was a sheet behind a button in the bar: a tap and a screen to
            // answer "what happens after this one".
            CastQueueInline()

            CastStopButton(title: "Stop casting") {
                cast.stopStream()
                dismiss()
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(PanuraTheme.background)
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

    /// One big button, with the skips either side of it in two sizes.
    ///
    /// Ten seconds is for a line of dialogue missed; a minute is for a scene,
    /// an advert, or catching someone up who just walked in — six taps on the
    /// ten-second button was the complaint. The minutes sit outside the
    /// seconds, so the row reads outwards from the middle: the further from
    /// play, the bigger the jump.
    private var transport: some View {
        HStack(spacing: 14) {
            CastGlyphButton(
                system: "gobackward.60", size: 21, diameter: 44, label: "Back one minute"
            ) { cast.seek(byMs: -60_000) }

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

            CastGlyphButton(
                system: "goforward.60", size: 21, diameter: 44, label: "Forward one minute"
            ) { cast.seek(byMs: 60_000) }
        }
        .padding(.vertical, 2)
    }

    // MARK: volume

    /// Two buttons, not a slider.
    ///
    /// A slider asks for a value; nobody wants a *value* for the volume of a
    /// television across the room — they want it a bit louder, and then a bit
    /// louder again. Two taps do that without looking at the phone, where a
    /// slider needs a thumb found and dragged, and it is also what every
    /// physical remote in the house does.
    private var volumePill: some View {
        HStack(spacing: 0) {
            volumeStep("minus", to: playback.volume - 0.05, label: "Quieter")

            VStack(spacing: 1) {
                Image(systemName: speakerGlyph)
                    .font(.system(size: 12))
                    .foregroundStyle(PanuraTheme.accent)
                Text("\(Int((playback.volume * 100).rounded()))%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)

            volumeStep("plus", to: playback.volume + 0.05, label: "Louder")
        }
        .frame(maxWidth: .infinity)
        .frame(height: PanuraCastControlView.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanuraTheme.surfaceVariant)
        )
    }

    private func volumeStep(_ glyph: String, to value: Float, label: String) -> some View {
        Button {
            cast.setVolume(min(1, max(0, value)))
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .frame(width: 40, height: PanuraCastControlView.pillHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var speakerGlyph: String {
        if playback.volume <= 0.001 { return "speaker.slash.fill" }
        if playback.volume < 0.34 { return "speaker.fill" }
        if playback.volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    /// Whatever the stream carries, plus the volume, on one line. Two controls
    /// when there are no subtitles, three when there are.
    private var secondaryControls: some View {
        HStack(spacing: 10) {
            if !playback.audioTracks.isEmpty {
                audioPill
            }
            if !playback.subtitleTracks.isEmpty {
                subtitlePill
            }
            volumePill
        }
    }

    // MARK: tracks

    /// Two pills rather than two table rows, and only for what the stream
    /// actually carries — a file with one audio track has nothing to choose
    /// between, and a row that always says "Default" teaches people to stop
    /// reading this part of the screen.
    private var audioPill: some View {
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

    private var subtitlePill: some View {
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
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: PanuraCastControlView.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanuraTheme.surfaceVariant)
        )
    }

    /// One height for every control on that row, so three different things
    /// still read as one row.
    static let pillHeight: CGFloat = 46

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

/// Done, and what this screen is.
///
/// It carried a queue button too, until the queue moved onto the screen itself.
/// A button leading to a list that is already visible is a button that has to
/// be explained.
struct CastControlBar: View {
    /// The television. Named here rather than under the poster, because the
    /// first question this screen answers is where the video went, and a screen
    /// that says "Playing on TV" at the top and names the TV three lines lower
    /// answers it twice and badly.
    var device: String?
    /// Direct, or through this phone.
    var note: String?
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

            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Text("Playing on")
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                CastMark(connected: true)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(PanuraTheme.accent)
                Text(device ?? "TV")
                    .font(.subheadline.weight(.semibold))
                if let note {
                    Text("·")
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            // Balances Done, so the title sits in the middle of the bar rather
            // than in the middle of what is left of it.
            Color.clear.frame(width: 38, height: 38)
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
    var isLive = false
    /// The page's poster, or a library thumbnail. There is no frame to take
    /// from the video itself — it is playing on a television — so this is the
    /// only picture there is, and a screen with one is a different screen.
    var posterURL: URL?
    var posterImage: UIImage?

    private var hasPoster: Bool { posterURL != nil || posterImage != nil }

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if hasPoster {
                    // Sixteen by nine, because that is the shape of what is on
                    // the TV. The square tile is for the glyph, which is a mark
                    // rather than a picture.
                    PosterThumb(
                        url: posterURL, image: posterImage, fallback: "tv.fill",
                        width: 208, height: 117, corner: 18
                    )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(PanuraTheme.surfaceVariant)
                            .frame(width: 128, height: 128)
                        Image(systemName: "tv.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(PanuraTheme.accent)
                    }
                }
            }
            .padding(.top, 6)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if isLive {
                    Text("LIVE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A transport glyph that is not the play button.
struct CastGlyphButton: View {
    let system: String
    var size: CGFloat = 26
    /// The tap target, which is also what gives the glyph its rank in the row.
    var diameter: CGFloat = 52
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(size < 24 ? PanuraTheme.onSurfaceVariant : .primary)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// What is lined up, under the controls for what is playing.
///
/// A queue belongs on the screen it is a queue for. It was a sheet behind a
/// button, which made "what happens after this one" a question you had to know
/// to ask — and the answer arrived as a screen covering the thing it was about.
///
/// A `List` rather than a stack of rows, because reordering is the whole point
/// of showing it and `onMove` is not something worth rewriting. Reordering is a
/// mode, though, not the resting state: with the drag handles always out, the
/// rows stop responding to an ordinary tap, and tapping one to play it now is
/// the commonest correction by a distance.
struct CastQueueInline: View {
    @ObservedObject private var flow = CastFlow.shared
    @State private var reordering = false

    /// Tall enough for three, then it scrolls. The controls above are the
    /// subject of the screen; this is what comes next.
    private var height: CGFloat { min(CGFloat(flow.queue.count) * 56 + 6, 190) }

    var body: some View {
        if !flow.queue.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                list
            }
            // Clear of the row above it: without this the first queued row sat
            // against the audio and subtitle controls as though it were part of
            // them.
            .padding(.top, 18)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Up next · \(flow.queue.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Spacer(minLength: 0)
            Button(reordering ? "Done" : "Reorder") {
                withAnimation(.easeOut(duration: 0.18)) { reordering.toggle() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PanuraTheme.accent)
            Button("Clear") { flow.clearQueue() }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
        .padding(.horizontal, 22)
    }

    private var list: some View {
        List {
            ForEach(flow.queue) { item in
                Button {
                    // Play it now: everything else keeps its order behind it.
                    flow.replace(with: [item] + flow.queue.filter { $0.id != item.id })
                } label: {
                    HStack(spacing: 10) {
                        PosterThumb(
                            url: item.posterURL, image: item.posterImage,
                            fallback: item.isStream ? "globe" : "film",
                            width: 48, height: 28
                        )
                        Text(item.title)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 16))
                .listRowSeparatorTint(PanuraTheme.outlineVariant)
            }
            .onDelete { offsets in
                for index in offsets.sorted(by: >) where flow.queue.indices.contains(index) {
                    flow.remove(flow.queue[index])
                }
            }
            .onMove { source, destination in
                flow.move(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(reordering ? .active : .inactive))
        .frame(height: height)
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
