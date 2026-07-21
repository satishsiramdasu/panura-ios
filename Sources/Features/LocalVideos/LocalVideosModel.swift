import SwiftUI
import Photos
import AVFoundation

struct LocalVideoAsset: Identifiable {
    let id: String
    let title: String
    let asset: PHAsset
    var thumbnail: UIImage?
}

@MainActor
final class LocalVideosModel: ObservableObject {
    enum State {
        case loading, needsPermission, empty, loaded([LocalVideoAsset])
    }
    @Published var state: State = .loading

    private let imageManager = PHCachingImageManager()

    func load() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited: await fetch()
        case .notDetermined: state = .needsPermission
        default: state = .needsPermission
        }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if status == .authorized || status == .limited { await fetch() }
        else { state = .needsPermission }
    }

    private func fetch() async {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        guard result.count > 0 else { state = .empty; return }

        var items: [LocalVideoAsset] = []
        result.enumerateObjects { asset, _, _ in
            let title = (asset.value(forKey: "filename") as? String) ?? "Video"
            items.append(LocalVideoAsset(id: asset.localIdentifier, title: title, asset: asset))
        }
        state = .loaded(items)
        await loadThumbnails(for: items)
    }

    private func loadThumbnails(for items: [LocalVideoAsset]) async {
        var updated = items
        let size = CGSize(width: 300, height: 200)
        // highQualityFormat delivers a single callback; combined with the
        // resume-once guard this avoids the double-resume crash that
        // PHImageManager's default (opportunistic) delivery causes.
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        for (i, item) in items.enumerated() {
            let image: UIImage? = await withCheckedContinuation { cont in
                var resumed = false
                imageManager.requestImage(
                    for: item.asset, targetSize: size,
                    contentMode: .aspectFill, options: options
                ) { img, info in
                    // Ignore the degraded placeholder; only resume once.
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded { return }
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(returning: img)
                }
            }
            updated[i].thumbnail = image
        }
        state = .loaded(updated)
    }

    func resolveURL(for item: LocalVideoAsset) async -> URL? {
        await withCheckedContinuation { cont in
            var resumed = false
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            imageManager.requestAVAsset(forVideo: item.asset, options: options) { avAsset, _, _ in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }
}
