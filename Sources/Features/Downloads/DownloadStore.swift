import Foundation
import UIKit

/// One saved video, and what is known about it.
///
/// Ported from Android's `OfflineVideoEntity`. Kept as a JSON list in
/// Application Support rather than a database: a few dozen rows, read whole on
/// launch, written on every state change.
struct DownloadEntry: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case queued, downloading, paused, complete, failed
        /// The site refused the link — 401/403/404/410, or an error page where
        /// the playlist should be. Retrying the same link cannot help; only a
        /// fresh one from the page can, so the UI offers Open page instead.
        case expired
    }

    let id: UUID
    var title: String
    /// The page the stream was found on — what Open page reopens.
    var pageURL: String
    var streamURL: String
    var headers: [String: String]
    /// The page's poster, shown at 120x68.
    var poster: String?
    var status: Status
    var isHLS: Bool
    /// The file the player opens once complete: the local playlist for HLS,
    /// the file itself otherwise. Relative to the downloads folder.
    var localPath: String?
    var sizeBytes: Int64 = 0
    var durationSeconds: Double = 0
    var created = Date()
    /// Progress as last measured: segments for HLS, bytes for a file.
    var done: Int64 = 0
    var total: Int64 = 0

    var progress: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var folder: URL { DownloadStore.root.appendingPathComponent(id.uuidString, isDirectory: true) }
    var playableURL: URL? { localPath.map { DownloadStore.root.appendingPathComponent($0) } }
}

/// Downloads: the list, and the work.
///
/// **HLS is stored as HLS** — every segment saved byte for byte under its own
/// name and the playlist rewritten to point at them. Nothing is concatenated
/// or remuxed, which is the design Android arrived at after a remux quietly
/// broke audio. Segments are fetched four at a time; a segment already on disk
/// is skipped, which is all resume needs.
///
/// **Pausing is not failing.** Pause cancels the task; the cancellation is
/// caught and the entry keeps `paused`, with everything on disk kept.
///
/// iOS suspends an app shortly after it leaves the foreground, and a download
/// suspended mid-segment simply continues from disk the next time it runs.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var entries: [DownloadEntry] = []
    /// Something finished that has not been looked at — the header's dot.
    @Published var unseen = false

    private var tasks: [UUID: Task<Void, Never>] = [:]

    nonisolated static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Not backed up: these are re-fetchable, and can be gigabytes.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = dir
        try? marked.setResourceValues(values)
        return dir
    }()

    private static var listURL: URL { root.appendingPathComponent("downloads.json") }

    var isDownloading: Bool { entries.contains { $0.status == .downloading || $0.status == .queued } }

    /// Overall progress across running downloads, nil while none knows its size.
    var runningProgress: Double? {
        let running = entries.filter { $0.status == .downloading && $0.total > 0 }
        guard !running.isEmpty else { return nil }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    private init() {
        if let data = try? Data(contentsOf: Self.listURL),
           let saved = try? JSONDecoder().decode([DownloadEntry].self, from: data) {
            // A run killed by the system was mid-download; it is paused now,
            // with its parts on disk.
            entries = saved.map { entry in
                var e = entry
                if e.status == .downloading || e.status == .queued { e.status = .paused }
                return e
            }
        }
    }

    // MARK: asking

    /// Starts a download, or resumes the stopped one from the same page.
    ///
    /// Re-saving from the same page reuses a stopped entry: the worker compares
    /// the new link's fingerprint with the one on disk, and continues onto the
    /// fresh URL when it is the same video, or wipes and starts over when not.
    @discardableResult
    func enqueue(
        title: String, pageURL: String, streamURL: URL, headers: [String: String],
        poster: String?, isHLS: Bool
    ) -> DownloadEntry {
        if let i = entries.firstIndex(where: {
            $0.pageURL == pageURL && $0.status != .complete
        }) {
            entries[i].streamURL = streamURL.absoluteString
            entries[i].headers = headers
            entries[i].status = .queued
            if let poster { entries[i].poster = poster }
            persist()
            start(entries[i].id)
            return entries[i]
        }
        let entry = DownloadEntry(
            id: UUID(), title: Self.clean(title), pageURL: pageURL,
            streamURL: streamURL.absoluteString, headers: headers, poster: poster,
            status: .queued, isHLS: isHLS
        )
        entries.insert(entry, at: 0)
        persist()
        start(entry.id)
        return entry
    }

    func pause(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) { $0.status = .paused }
    }

    func resume(_ id: UUID) {
        update(id) { $0.status = .queued }
        start(id)
    }

    func delete(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let entry = entries.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: entry.folder)
        }
        entries.removeAll { $0.id == id }
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        let name = Self.clean(title)
        guard !name.isEmpty else { return }
        update(id) { $0.title = name }
    }

    /// Done and what is left, read from disk — for a paused or stopped row,
    /// which has no live progress to show.
    func diskProgress(_ entry: DownloadEntry) -> (done: Int64, total: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: entry.folder, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        if entry.isHLS {
            let segments = files.filter {
                $0.lastPathComponent.hasPrefix("v") && $0.pathExtension != "part"
                    && $0.pathExtension != "m3u8" && $0.pathExtension != "fingerprint"
            }
            return (Int64(segments.count), entry.total)
        }
        let size = files.first { $0.lastPathComponent == "video" }
            .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        return (Int64(size ?? 0), entry.total)
    }

    // MARK: the work

    private func start(_ id: UUID) {
        guard tasks[id] == nil, let entry = entries.first(where: { $0.id == id }) else { return }
        update(id) { $0.status = .downloading }
        tasks[id] = Task { [weak self] in
            let worker = DownloadWorker(entry: entry) { done, total in
                Task { @MainActor in
                    self?.update(id, persisting: false) { $0.done = done; $0.total = total }
                }
            }
            do {
                let result = try await worker.run()
                await MainActor.run {
                    self?.update(id) {
                        $0.status = .complete
                        $0.localPath = result.relativePath
                        $0.sizeBytes = result.size
                        $0.durationSeconds = result.duration
                        $0.done = $0.total
                    }
                    self?.unseen = true
                    self?.tasks[id] = nil
                }
            } catch is CancellationError {
                // Paused or deleted: the caller already set the state, and the
                // parts on disk stay for the next run.
                await MainActor.run { self?.tasks[id] = nil }
            } catch {
                await MainActor.run {
                    self?.update(id) {
                        guard $0.status != .paused else { return }
                        $0.status = DownloadWorker.isLinkDead(error) ? .expired : .failed
                    }
                    self?.tasks[id] = nil
                }
            }
        }
    }

    private func update(_ id: UUID, persisting: Bool = true, _ change: (inout DownloadEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        if persisting { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.listURL, options: .atomic)
    }

    private static func clean(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Video" : String(trimmed.prefix(120))
    }
}
