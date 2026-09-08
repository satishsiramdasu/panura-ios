import SwiftUI
import Photos
import AVFoundation

struct LocalVideoAsset: Identifiable {
    let id: String
    let title: String
    let asset: PHAsset
    var thumbnail: UIImage?

    var duration: Double { asset.duration }
    var created: Date { asset.creationDate ?? .distantPast }
    var pixels: Int { asset.pixelWidth * asset.pixelHeight }

    /// "1:04:12" · "12:04" — the badge on the thumbnail.
    var durationLabel: String {
        let total = Int(duration.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    var resolutionLabel: String { "\(asset.pixelWidth)×\(asset.pixelHeight)" }
}

/// An album from the Photos library — the closest thing iOS has to Android's
/// folders, which is what the Videos tab is grouped by there.
struct VideoAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
}

@MainActor
final class LocalVideosModel: ObservableObject {
    enum State {
        case loading, needsPermission, empty, loaded([LocalVideoAsset])
    }

    /// Android's sort menu, minus the ones Photos cannot answer.
    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest first"
        case oldest = "Oldest first"
        case nameAZ = "Name A–Z"
        case nameZA = "Name Z–A"
        case longest = "Longest first"
        case shortest = "Shortest first"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .newest, .oldest: return "calendar"
            case .nameAZ, .nameZA: return "textformat"
            case .longest, .shortest: return "clock"
            }
        }
    }

    /// Grid or list, as Android's `MediaLayoutMode`. A list gives a long name
    /// room to be read, a grid gives a familiar thumbnail room to be
    /// recognised, and which one is wanted depends entirely on the library.
    enum Layout: String {
        case grid, list

        var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
        var next: Layout { self == .grid ? .list : .grid }
    }

    /// Remembered: this is a preference about a library that does not change
    /// between launches, so asking for it again every launch is asking twice.
    @Published var layout: Layout = .grid {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey) }
    }
    private static let layoutKey = "videos_layout"

    @Published var state: State = .loading
    @Published private(set) var albums: [VideoAlbum] = []
    /// nil = the whole library, which is where the tab opens.
    @Published var album: VideoAlbum?
    @Published var search = ""
    @Published var sort: SortOrder = .newest
    /// Title of the video currently being made playable. Getting a file out of
    /// the Photos library is not instant — an iCloud video has to come down
    /// first — and a tap that looks like it did nothing is the whole complaint.
    @Published var preparing: String?
    /// Why the last attempt failed, for the banner.
    @Published var error: String?

    private let imageManager = PHCachingImageManager()
    /// Everything loaded, before search and sort. The published list is derived.
    private var all: [LocalVideoAsset] = []
    /// Identifies the current load. Switching album starts a new fetch while the
    /// previous one is still walking its thumbnails; without this the old run
    /// finishes last and publishes the previous album's videos over the new
    /// ones — the grid then holds assets the album does not contain.
    private var loadToken = UUID()

    /// What the grid shows: the album's videos, narrowed by the search box and
    /// put in the chosen order.
    var visible: [LocalVideoAsset] {
        guard case .loaded(let items) = state else { return [] }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty
            ? items
            : items.filter { $0.title.lowercased().contains(query) }
        switch sort {
        case .newest:   return filtered.sorted { $0.created > $1.created }
        case .oldest:   return filtered.sorted { $0.created < $1.created }
        case .nameAZ:   return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .nameZA:   return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .longest:  return filtered.sorted { $0.duration > $1.duration }
        case .shortest: return filtered.sorted { $0.duration < $1.duration }
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.layoutKey),
           let saved = Layout(rawValue: raw) {
            layout = saved
        }
    }

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

    /// Re-read the library after a delete, or when the album changes.
    func reload() async { await fetch() }

    private func fetch() async {
        let token = UUID()
        loadToken = token
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)

        let result: PHFetchResult<PHAsset>
        if let album, let collection = Self.collection(id: album.id) {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: .video, options: options)
        }

        await loadAlbums()
        guard loadToken == token else { return }

        guard result.count > 0 else {
            all = []
            state = .empty
            return
        }

        var items: [LocalVideoAsset] = []
        result.enumerateObjects { asset, _, _ in
            let title = (asset.value(forKey: "filename") as? String) ?? "Video"
            items.append(LocalVideoAsset(id: asset.localIdentifier, title: title, asset: asset))
        }
        all = items
        state = .loaded(items)
        await loadThumbnails(for: items, token: token)
    }

    /// Albums holding at least one video. An album of stills is noise in a video
    /// picker, and Photos has plenty of those.
    private func loadAlbums() async {
        var found: [VideoAlbum] = []
        let videoOptions = PHFetchOptions()
        videoOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)

        func collect(_ collections: PHFetchResult<PHAssetCollection>) {
            collections.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: videoOptions).count
                guard count > 0 else { return }
                found.append(
                    VideoAlbum(
                        id: collection.localIdentifier,
                        title: collection.localizedTitle ?? "Album",
                        count: count
                    )
                )
            }
        }

        collect(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
        collect(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil))
        albums = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func collection(id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        ).firstObject
    }

    private func loadThumbnails(for items: [LocalVideoAsset], token: UUID) async {
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
            // Another album started loading while this was running; its list is
            // on screen and must not be overwritten with this one.
            guard loadToken == token else { return }
            updated[i].thumbnail = image
            // Assigning the whole array per thumbnail would relayout the grid
            // every time one arrives, so they go up a dozen at a time — a big
            // library then fills in as it loads instead of staying grey until
            // the last one is home.
            if i % 12 == 11 || i == items.count - 1 {
                all = updated
                state = .loaded(updated)
            }
        }
    }

    /// A playable file for one library video.
    ///
    /// Two paths, because `requestAVAsset` alone does not cover the library.
    /// It hands back an `AVURLAsset` for an ordinary recording, but an edited,
    /// slow-motion or otherwise composed video arrives as an `AVComposition`
    /// with no URL at all, and an iCloud video that has not come down yet
    /// arrives as nothing. Both cases used to end as `nil`, and a `nil` here
    /// meant the tap did nothing and said nothing — which is what "sometimes I
    /// can't play a video" was.
    ///
    /// So the fallback copies the original out of the library with
    /// `PHAssetResourceManager`, which downloads from iCloud when it has to and
    /// works for every asset the picker can show.
    func resolveURL(for item: LocalVideoAsset) async -> URL? {
        error = nil
        preparing = item.title
        defer { preparing = nil }

        if let url = await avAssetURL(for: item) { return url }
        if let url = await copyOriginal(for: item) { return url }
        error = "Couldn't open \"\(item.title)\". It may still be downloading from iCloud."
        return nil
    }

    private func avAssetURL(for item: LocalVideoAsset) async -> URL? {
        await withCheckedContinuation { cont in
            var resumed = false
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            imageManager.requestAVAsset(forVideo: item.asset, options: options) { avAsset, _, _ in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }

    /// Writes the asset's own file into the temporary directory and plays that.
    /// The copy is kept and reused — the same video played twice should not be
    /// fetched twice — and lives in the temporary directory, which the system
    /// clears on its own terms.
    private func copyOriginal(for item: LocalVideoAsset) async -> URL? {
        let resources = PHAssetResource.assetResources(for: item.asset)
        guard let resource = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first
        else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panura-library", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The identifier, not the filename: two videos can share a name, and an
        // identifier carries characters a path cannot.
        let key = String(item.id.prefix(36)).replacingOccurrences(of: "/", with: "_")
        let ext = (resource.originalFilename as NSString).pathExtension
        let destination = directory
            .appendingPathComponent(key)
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: destination, options: options
            ) { failure in
                cont.resume(returning: failure == nil ? destination : nil)
            }
        }
    }

    /// File size, read lazily — `PHAssetResource` is a separate fetch, so it is
    /// done for the one video whose info sheet is open rather than for all of
    /// them at load.
    func fileSize(for item: LocalVideoAsset) -> String? {
        guard let resource = PHAssetResource.assetResources(for: item.asset).first,
              let bytes = resource.value(forKey: "fileSize") as? Int64 else { return nil }
        return StreamProbe.formatSize(bytes)
    }

    /// Deletes through Photos, which puts up its own confirmation — the system
    /// owns that prompt and an app cannot skip it, which is exactly right for
    /// something irreversible.
    func delete(_ items: [LocalVideoAsset]) async -> Bool {
        let assets = items.map(\.asset) as NSArray
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, _ in
                cont.resume(returning: success)
            }
        }
    }
}
