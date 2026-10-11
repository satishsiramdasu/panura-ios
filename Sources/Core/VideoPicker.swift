import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One video, out of process, no permission.
///
/// `PHPickerViewController` runs in its own process and hands back only what
/// the user pointed at, so it needs **no photo-library authorisation of any
/// kind** — not even a usage string's worth of consent. That is what makes it
/// the right escape hatch on a screen that is asking for the library: somebody
/// who does not want to hand over their camera roll can still watch what is in
/// it, one video at a time.
///
/// Shared by Home's pick card and the Videos tab's permission screens, which
/// is why it lives here rather than beside either of them.
struct VideoPicker: UIViewControllerRepresentable {
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

/// What to do with what the picker handed back.
enum PickedVideo {
    /// Copies the picked video somewhere it will still exist when the player
    /// opens it, then plays it. `onFinish` runs on the main actor either way.
    ///
    /// The picker's file lives in a system staging directory that is torn down
    /// the moment the completion handler returns, so the copy is made inside
    /// the handler and the player is handed ours.
    static func play(_ provider: NSItemProvider, onFinish: @escaping (Bool) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
            let copied = url.flatMap(stage)
            Task { @MainActor in
                guard let copied else {
                    onFinish(false)
                    return
                }
                PlaybackSession.shared.play(
                    MediaItem(
                        title: copied.deletingPathExtension().lastPathComponent,
                        url: copied,
                        isLocal: true
                    )
                )
                onFinish(true)
            }
        }
    }

    /// Same folder every time, and the previous pick is cleared first — a
    /// picked video is a one-shot, and keeping them would quietly fill the
    /// temporary directory with whole films.
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
