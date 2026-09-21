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
    @Environment(\.dismiss) private var dismiss

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
        .presentationDragIndicator(.visible)
    }

    /// Whichever receiver has the video. Nothing playing anywhere falls through
    /// to the picker, since the screen was opened to reach a TV.
    @ViewBuilder
    private var controls: some View {
        if panura.isCasting {
            PanuraCastControlView()
        } else if chromecast.isCasting {
            ChromecastControlView()
        } else {
            NavigationStack { CastDevicesView() }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cast.castingTitle ?? "Video")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            CastMark(connected: true).frame(width: 14, height: 14)
                            Text(cast.connectedDeviceName ?? "Chromecast")
                            if !cast.remoteTimeLeft.isEmpty {
                                Text("·")
                                Text(cast.remoteTimeLeft)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    }
                } header: { Text("Playing on TV") }

                Section {
                    Button {
                        cast.toggleRemotePlay()
                    } label: {
                        Label(
                            cast.isRemotePlaying ? "Pause" : "Play",
                            systemImage: cast.isRemotePlaying ? "pause.fill" : "play.fill"
                        )
                    }
                } header: { Text("Controls") }

                Section {
                    Button("Stop casting", role: .destructive) {
                        cast.stopRemote()
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
}
