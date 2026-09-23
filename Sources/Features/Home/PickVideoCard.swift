import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Home's "pick a video and play it" card.
///
/// Sits where the cast card used to. Casting is something you reach for *after*
/// you have chosen something to watch, which made it the last card on a screen
/// people open to start watching; picking a video is the start of that, so it
/// goes above the destinations rather than below them.
///
/// `PHPickerViewController` runs out of process and needs **no photo library
/// permission at all** — it hands back only what the user pointed at. So this
/// works for someone who refused the Videos tab, which is most of the point of
/// having it: one tap, one video, no setup and no dialog.
struct PickVideoCard: View {
    @State private var picking = false
    @State private var preparing = false

    var body: some View {
        Button { picking = true } label: { card }
            .buttonStyle(.plain)
            .disabled(preparing)
            .accessibilityLabel("Pick a video to play")
            .sheet(isPresented: $picking) {
                VideoPicker(onPick: prepare)
                    .ignoresSafeArea()
            }
    }

    private var card: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 42, height: 42)
                .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("Pick a video")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(preparing ? "Getting it ready…" : "Play one from this phone, right now")
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if preparing {
                ProgressView()
                    .tint(PanuraTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                Text("Browse")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PanuraTheme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(PanuraTheme.accent, in: Capsule())
            }
        }
        .padding(12)
        .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Copies the picked video somewhere it will still exist when the player
    /// opens it.
    ///
    /// The picker's file lives in a system staging directory that is torn down
    /// the moment the completion handler returns, so the copy is made inside
    /// the handler and the player is handed ours. Same folder every time, and
    /// the previous pick is cleared first — a picked video is a one-shot, and
    /// keeping them would quietly fill the temporary directory with whole
    /// films.
    private func prepare(_ provider: NSItemProvider) {
        preparing = true
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
            let copied = url.flatMap(Self.stage)
            Task { @MainActor in
                preparing = false
                guard let copied else { return }
                PlaybackSession.shared.play(
                    MediaItem(
                        title: copied.deletingPathExtension().lastPathComponent,
                        url: copied,
                        isLocal: true
                    )
                )
            }
        }
    }

    private static func stage(_ source: URL) -> URL? {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("panura-picked", isDirectory: true)
        try? manager.removeItem(at: directory)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            try manager.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}

/// One video, out of process, no permission.
private struct VideoPicker: UIViewControllerRepresentable {
    let onPick: (NSItemProvider) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        // Hand back the file as it is stored rather than a transcode. The app
        // has two playback engines precisely so it does not need Apple's
        // compatibility copy of anything.
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (NSItemProvider) -> Void

        init(onPick: @escaping (NSItemProvider) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            onPick(provider)
        }
    }
}
