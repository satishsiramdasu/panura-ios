import SwiftUI

/// The one screen for "what is happening with the TV".
///
/// It covers the whole arc — reading the file, converting it, handing it over,
/// and then playing — because those are one event to the person watching, even
/// though they are three unrelated mechanisms in the code. Before this, the
/// first three were invisible and only the last had a screen, so a Dolby Vision
/// clip looked like a phone that had stopped responding.
///
/// Once the video is on the TV this steps out of the way and shows the controls
/// for whichever receiver has it. The two are not interchangeable: Panura's own
/// receiver reports position, tracks and volume, and a Chromecast reports far
/// less, so pretending they are the same screen would mean showing dead
/// controls on one of them.
struct CastSessionView: View {
    @ObservedObject private var flow = CastFlow.shared
    @ObservedObject private var panura = PanuraCastManager.shared
    @ObservedObject private var chromecast = CastManager.shared
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.castPageClose) private var pageClose

    /// Closes the cast page. It is a layer in the shell rather than a
    /// presentation, so the system's dismiss has nothing to act on there.
    private func dismiss() {
        if let pageClose { pageClose() } else { systemDismiss() }
    }

    var body: some View {
        Group {
            switch flow.stage {
            case .idle, .playing:
                controls
            case let .reading(title):
                busy(
                    title: title,
                    caption: "Getting the video ready",
                    detail: "Reading it out of your library. A video still in iCloud is fetched first.",
                    progress: nil
                )
            case let .converting(title, explanation, progress, overridable):
                busy(
                    title: title, caption: "Preparing for the TV",
                    detail: explanation, progress: progress, overridable: overridable
                )
            case let .sending(title, device):
                busy(
                    title: title,
                    caption: "Sending to \(device)",
                    detail: "The video is served from this phone, so keep it on the network and awake.",
                    progress: nil
                )
            case let .failed(message):
                failure(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanuraTheme.background)
        // No banner of its own: this page is a layer inside the shell, above
        // everything but the shell's bottom edge, so the app's one banner stays
        // where it is underneath. See `RootTabView.shell`.
        .accessibilityAddTraits(.isModal)
    }

    /// Whichever receiver has the video. Nothing playing anywhere falls through
    /// to the picker, since the screen was opened to reach a TV.
    @ViewBuilder
    private var controls: some View {
        if panura.isCasting {
            PanuraCastControlView()
        } else if chromecast.isCasting {
            ChromecastControlView()
        } else if !flow.queue.isEmpty {
            // Nothing on the TV yet but things lined up for it — the queue is
            // the whole story, so it gets the screen to itself.
            NavigationStack { CastQueueView() }
        } else {
            // Nothing on any television. The picker is a panel at the root now
            // and cannot be drawn above this sheet, so this closes and opens it
            // — which is also the honest order of events: there is nothing to
            // control until a TV has been chosen.
            VStack(spacing: 14) {
                CastMark()
                    .frame(width: 34, height: 34)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                Text("Nothing is on a TV").font(.headline)
                Button("Choose a television") {
                    dismiss()
                    CastPicker.shared.open()
                }
                .buttonStyle(.borderedProminent)
                .tint(PanuraTheme.accent)
                // Needed now the screen is a page. As a sheet this state could
                // be swiped away, so the only button it had to offer was the
                // one that goes forward.
                Button("Close") { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanuraTheme.background)
        }
    }

    /// One layout for all three waiting states, because they differ only in what
    /// they can honestly say. A determinate bar appears only where there is a
    /// real number behind it — a fake one that sits at 90% teaches people to
    /// distrust every bar in the app.
    private func busy(
        title: String, caption: String, detail: String,
        progress: Float?, overridable: Bool = false
    ) -> some View {
        VStack(spacing: 18) {
            CastMark(connected: true)
                .frame(width: 44, height: 44)
                .foregroundStyle(PanuraTheme.accent)

            VStack(spacing: 6) {
                Text(caption).font(.headline)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if let progress {
                VStack(spacing: 6) {
                    ProgressView(value: Double(progress)).tint(PanuraTheme.accent)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            } else {
                ProgressView().tint(PanuraTheme.accent)
            }

            Text(detail)
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { flow.cancel() }
                    .buttonStyle(.bordered)

                // Only where the conversion is a judgement about this TV, not
                // a limit of the receiver.
                if overridable {
                    Button("Send original") { flow.sendOriginal() }
                        .buttonStyle(.borderedProminent)
                        .tint(PanuraTheme.accent)
                }
            }
            .font(.subheadline)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(PanuraTheme.surface)
        .presentationDetents([.height(progress == nil ? 300 : 340)])
        // The work carries on behind a dismissed sheet, and there would be no
        // way back to the Cancel that stops it.
        .interactiveDismissDisabled()
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("That did not reach the TV").font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { flow.cancel() }
                .buttonStyle(.borderedProminent)
                .tint(PanuraTheme.accent)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(PanuraTheme.surface)
        .presentationDetents([.height(280)])
    }
}

/// What a Chromecast can actually be asked.
///
/// Far less than Panura's own receiver, and the screen says only what is true:
/// the SDK reports whether it is playing and how much is left, and takes
/// play/pause and stop. No scrubber, because a position this screen cannot
/// trust would be a slider that fights the TV.
struct ChromecastControlView: View {
    @ObservedObject private var cast = CastManager.shared
    @ObservedObject private var flow = CastFlow.shared
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.castPageClose) private var pageClose

    /// Closes the cast page. It is a layer in the shell rather than a
    /// presentation, so the system's dismiss has nothing to act on there.
    private func dismiss() {
        if let pageClose { pageClose() } else { systemDismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            CastControlBar(
                device: cast.connectedDeviceName ?? "Chromecast",
                note: cast.remoteTimeLeft.isEmpty ? nil : cast.remoteTimeLeft,
                onDone: { dismiss() }
            )

            ScrollView {
                VStack(spacing: 26) {
                    CastHero(
                        title: cast.castingTitle ?? "Video",
                        posterURL: CastFlow.shared.nowPlaying?.posterURL,
                        posterImage: CastFlow.shared.nowPlaying?.posterImage
                    )

                    // The one control the receiver answers for. No scrubber and
                    // no skips: a position this screen cannot trust would be a
                    // slider that fights the TV.
                    Button { cast.toggleRemotePlay() } label: {
                        Image(systemName: cast.isRemotePlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(PanuraTheme.onAccent)
                            .frame(width: 74, height: 74)
                            .background(Circle().fill(PanuraTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(cast.isRemotePlaying ? "Pause" : "Play")

                    castError

                    muxToggle

                    audioPicker

                    subtitlePicker

                    PhoneRelayNotice()

                    Text("This television is a Chromecast, so play and pause are all it reports back.")
                        .font(.caption)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }

            CastQueueInline()

            CastStopButton(title: "Stop casting") {
                cast.stopRemote()
                dismiss()
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(PanuraTheme.background)
    }

    /// What the receiver said when it refused.
    ///
    /// On screen rather than in a log, because the television is the only part
    /// of this that knows anything and a phone with no console attached is
    /// where these get reported from. The Cast error code is the useful half —
    /// 3116403 is a manifest the server refused, 3115xxx is media that could
    /// not be played — so it is printed as given rather than softened into
    /// "something went wrong".
    @ViewBuilder
    private var castError: some View {
        if let message = cast.lastCastError ?? (cast.slowToStart
            ? "The TV is taking a long time to start this. Chromecast TVs sometimes get stuck; if nothing happens, stop casting, restart the TV and try again."
            : nil) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(PanuraTheme.error)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
            .textSelection(.enabled)
        }
    }

    /// The switch for a television whose Chromecast cannot play audio and
    /// video as two separate streams.
    ///
    /// **On by default, and here to be turned off.** A master that declares
    /// its audio separately is unplayable on this hardware, so the switch
    /// starts on and the first attempt works; what it exists for is the
    /// television that turns out to manage the original perfectly well, which
    /// should not be made to pay for the bytes. That answer cannot be
    /// detected either — a set that lacks the second pipeline shows one frame
    /// and stops, which is also what a slow network, a refused manifest and an
    /// undecodable codec look like from the sofa — so the person in front of
    /// it is the only judge, and their answer is kept against that set's name.
    /// See `CastPreferences.muxingChoice`.
    ///
    /// Shown only where it could matter: an HLS stream whose audio is declared
    /// separately. Anywhere else the audio is already inside the video, and a
    /// switch that changes nothing would send somebody chasing the wrong
    /// fault.
    @ViewBuilder
    private var muxToggle: some View {
        if flow.canMux {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { flow.muxWanted }, set: { flow.setMuxing($0) })) {
                    Text("Combine sound into the picture")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(PanuraTheme.accent)
                .disabled(flow.reloading)

                Text(muxCaption)
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Four states, and the two in the middle are why this is not one string:
    /// the switch says what is wanted, this says what is actually happening.
    private var muxCaption: String {
        if flow.reloading { return "Preparing the stream…" }
        if flow.muxUnavailable {
            return "This video cannot be combined on the phone — a live "
                + "channel, encrypted segments, or a format this cannot open. "
                + "It has been sent the ordinary way instead."
        }
        if flow.isMuxing {
            return "The phone is joining the picture and sound for this "
                + "video, so keep it on this network and awake while the film "
                + "plays."
        }
        return "On for televisions that start a video and stop a few seconds "
            + "in. Only used where a video needs it — this one did not, and "
            + "is streaming straight from the source."
    }

    /// Which audio is on the television, and how to change it.
    ///
    /// **Only for a stream that had more than one to begin with.** A
    /// Chromecast cannot play alternate audio, so whatever the phone built for
    /// it carries exactly one track — whether that was a filtered master or a
    /// muxed stream. The receiver therefore has no track list to report, and
    /// this is the only place the choice exists at all; it is read from what
    /// the phone built, not from anything the television says.
    ///
    /// Absent entirely for a single-audio stream, which is most of them. A row
    /// reading "Audio: Default" with one option under it teaches people to
    /// stop reading this part of the screen.
    @ViewBuilder
    private var subtitlePicker: some View {
        if !cast.remoteSubtitles.isEmpty {
            Menu {
                Button {
                    cast.selectSubtitle(nil)
                } label: {
                    Label("Off", systemImage: cast.activeSubtitle == nil ? "checkmark" : "")
                }
                ForEach(cast.remoteSubtitles) { sub in
                    Button {
                        cast.selectSubtitle(sub.id)
                    } label: {
                        Label(sub.name, systemImage: cast.activeSubtitle == sub.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 13, weight: .semibold))
                    Text(cast.remoteSubtitles.first { $0.id == cast.activeSubtitle }?.name ?? "Subtitles off")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(PanuraTheme.accent)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(PanuraTheme.accentSoft, in: Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel("Subtitles")
        }
    }

    @ViewBuilder
    private var audioPicker: some View {
        if flow.tracks.count > 1 {
            VStack(spacing: 6) {
                Menu {
                    ForEach(flow.tracks) { track in
                        Button {
                            flow.changeAudio(to: track.id)
                        } label: {
                            Label(
                                track.label,
                                systemImage: track.id == flow.chosenTrack ? "checkmark" : ""
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .semibold))
                        Text(flow.tracks.first { $0.id == flow.chosenTrack }?.label ?? "Audio")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(PanuraTheme.accent)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(PanuraTheme.accentSoft, in: Capsule())
                    .contentShape(Capsule())
                }

                Text("Changing audio restarts the video on the TV from where it is now.")
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .accessibilityLabel("Audio track")
        }
    }
}

/// What is lined up for the TV.
///
/// Shown on its own when nothing is playing yet, and as a section inside the
/// controls once something is. Reorderable and removable, because a queue you
/// cannot change is a list of regrets — and "Play now" is there because the
/// commonest correction is wanting one of them immediately rather than fourth.
struct CastQueueView: View {
    @ObservedObject private var flow = CastFlow.shared
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.castPageClose) private var pageClose

    /// Closes the cast page. It is a layer in the shell rather than a
    /// presentation, so the system's dismiss has nothing to act on there.
    private func dismiss() {
        if let pageClose { pageClose() } else { systemDismiss() }
    }

    var body: some View {
        List {
            if let playing = flow.nowPlaying {
                Section {
                    Label(playing.title, systemImage: "play.fill")
                        .font(.subheadline)
                        .lineLimit(2)
                } header: { Text("On the TV") }
            }

            Section {
                if flow.queue.isEmpty {
                    Text("Nothing queued")
                        .font(.footnote)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                } else {
                    ForEach(flow.queue) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.isStream ? "globe" : "film")
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                            Text(item.title).font(.subheadline).lineLimit(2)
                        }
                        .contextMenu {
                            Button {
                                flow.replace(with: [item] + flow.queue.filter { $0.id != item.id })
                            } label: { Label("Play now", systemImage: "play.fill") }
                            Button(role: .destructive) {
                                flow.remove(item)
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { flow.remove(flow.queue[index]) }
                    }
                    .onMove { source, destination in
                        flow.move(from: source, to: destination)
                    }
                }
            } header: {
                Text(flow.queue.isEmpty ? "Up next" : "Up next · \(flow.queue.count)")
            }

            if !flow.queue.isEmpty {
                Section {
                    Button("Clear queue", role: .destructive) { flow.clearQueue() }
                }
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { EditButton() }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}

private struct CastPageCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by the shell on the cast page it draws as a layer.
    var castPageClose: (() -> Void)? {
        get { self[CastPageCloseKey.self] }
        set { self[CastPageCloseKey.self] = newValue }
    }
}

/// Says so when the television is getting the video through this phone.
///
/// In that case the cast lasts exactly as long as the phone keeps serving it.
/// Leave the app and iOS suspends it within seconds, the TV's next request goes
/// unanswered, and the film stops with nothing on either screen to say why.
/// Auto-lock is held off for as long as this applies — see `RootTabView`.
struct PhoneRelayNotice: View {
    @ObservedObject private var panura = PanuraCastManager.shared
    @ObservedObject private var chromecast = CastManager.shared

    private var reason: String? { Self.reason(panura: panura, chromecast: chromecast) }

    @MainActor
    static func reason(panura: PanuraCastManager, chromecast: CastManager) -> String? {
        if panura.isCasting, panura.mode == "proxy" {
            return panura.castID.hasPrefix("file:")
                ? PhoneRelay.file.reason
                : "This video can't be opened by the TV directly, so it is passing through your phone."
        }
        if chromecast.isCasting, let relay = panura.chromecastRelay {
            return relay.reason
        }
        return nil
    }

    var body: some View {
        if let reason {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PanuraTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Playing through this phone")
                        .font(.subheadline.weight(.semibold))
                    Text(reason + " Keep Panura open and on the same Wi-Fi until it finishes.")
                        .font(.caption)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
