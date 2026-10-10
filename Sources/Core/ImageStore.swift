import SwiftUI
import UIKit

/// The app's picture cache: one fetch per URL, decoded once, kept on disk.
///
/// `AsyncImage` has no cache of any kind. It holds its image in the `@State`
/// of the view it is in, so a tile that scrolls out of a `LazyVGrid` is torn
/// down and the next appearance starts the download again from nothing. That
/// is tolerable for the handful of favicons Home draws. It is not tolerable
/// for an Xtream catalogue: a few hundred 2:3 posters, three to a row, every
/// one of them refetched and re-decoded each time it crosses the edge of the
/// screen — somebody's data spent over and over on pictures they have already
/// been shown, and a grid that stutters while it happens.
///
/// Three layers, because they fix three different costs:
///
/// - **Decoded images in memory** (`NSCache`). The expensive part of showing a
///   poster is turning JPEG bytes into a bitmap, not fetching them. Costed by
///   bitmap size and bounded, so the system can evict under pressure rather
///   than the app being killed for holding four hundred posters.
/// - **Bytes on disk** (`URLCache` on a private session). Survives relaunch
///   and eviction, and honours the CDN's own validators — a poster that has
///   not changed comes back as a 304 with no body.
/// - **One task per URL** (`inFlight`). Three visible tiles of the same
///   channel logo, or a grid scrolled back and forth before the first fetch
///   lands, must not be three requests.
///
/// Shared by every remote picture in the app rather than being an IPTV
/// nicety: favicons, resume thumbnails and channel logos all want exactly
/// this, and a second cache would be a second set of limits to tune.
///
/// **Not a `@MainActor` type, and not an actor.** `RemoteImage` reads the
/// memory cache from its `init` so a picture it has already shown is drawn on
/// the first frame instead of after a state change, and neither of those
/// isolations can be read from synchronously. `NSCache` is thread-safe on its
/// own; the one piece of mutable state that is not, `inFlight`, is held under
/// a lock — the same arrangement `StreamProxy` uses for the same reason.
final class ImageStore {
    static let shared = ImageStore()

    /// Bounded by bitmap bytes, not by count, because a poster and a favicon
    /// differ by two orders of magnitude and a count limit would either hold
    /// too few posters or far too many favicons.
    ///
    /// `NSCache` evicts under memory pressure on its own, which is the whole
    /// reason for using it over a dictionary.
    private let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// In-flight fetches, so the same URL is asked for once however many tiles
    /// want it. Guarded by `lock`.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    /// A session of our own, with a disk cache. Not `URLSession.shared`: its
    /// cache is shared with every other request the app makes, including
    /// stream probes, and a catalogue of posters would evict all of it.
    ///
    /// In `Caches/`, so the system may reclaim the space and the user's backup
    /// never carries a quarter of a gigabyte of other people's artwork.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 192 * 1024 * 1024,
            directory: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("Artwork", isDirectory: true)
        )
        // Posters do not change. Prefer what is already here and only ask the
        // network when nothing is.
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private init() {}

    /// What is already decoded, for a view that wants to draw on its first
    /// frame rather than flash a placeholder at something it has shown before.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The picture, from wherever it is cheapest.
    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }

        lock.lock()
        if let running = inFlight[url] {
            lock.unlock()
            return await running.value
        }
        let session = self.session
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await session.data(from: url) else { return nil }
            // A 404 body is not a picture, and `UIImage(data:)` would usually
            // agree — but an error page is occasionally decodable as
            // something, and an error page cached as artwork is permanent.
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return nil }
            guard !data.isEmpty, let raw = UIImage(data: data) else { return nil }
            // Decoded here, which is the point of the exercise: this task is
            // not on the main actor, so `preparingForDisplay` does the bitmap
            // work off the main thread instead of during the first draw.
            return raw.preparingForDisplay() ?? raw
        }
        inFlight[url] = task
        lock.unlock()

        let image = await task.value

        lock.lock()
        inFlight[url] = nil
        lock.unlock()

        if let image {
            memory.setObject(image, forKey: url as NSURL, cost: image.bitmapBytes)
        }
        return image
    }

    /// Everything, on the way out of Clear Data. The disk cache goes with it —
    /// artwork is the bulk of what that directory holds.
    func clear() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
}

private extension UIImage {
    /// What this costs the cache: the bitmap, not the file it came from. A
    /// 40 KB JPEG of a 1000×1500 poster is six megabytes in memory, and
    /// costing it by its download size is how a cache with a sane-looking
    /// limit ends up holding a gigabyte.
    var bitmapBytes: Int {
        guard let cg = cgImage else {
            return Int(size.width * scale * size.height * scale) * 4
        }
        return max(1, cg.bytesPerRow * cg.height)
    }
}
