import Foundation
import Combine

/// Download state for offline playback. On iOS, direct .mp4 files download via
/// URLSession; HLS (.m3u8) requires AVAssetDownloadURLSession for a proper
/// offline asset. This manager handles progressive files; HLS offline is a TODO
/// to wire through AVAssetDownloadTask.
struct DownloadJob: Identifiable {
    let id = UUID()
    let title: String
    let remoteURL: URL
    var progress: Double = 0
    var localURL: URL?
    var isFinished: Bool { localURL != nil }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var jobs: [DownloadJob] = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.panura.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    func start(_ item: MediaItem) {
        // TODO: branch to AVAssetDownloadTask when item.url is an .m3u8 playlist.
        let job = DownloadJob(title: item.title, remoteURL: item.url)
        jobs.append(job)
        Task { await download(job) }
        AdManager.shared.showInterstitial(.downloads)
    }

    private func download(_ job: DownloadJob) async {
        do {
            let (tempURL, _) = try await session.download(from: job.remoteURL)
            let dest = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(job.remoteURL.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[idx].localURL = dest
                jobs[idx].progress = 1
            }
        } catch {
            // Leave the job in-list at last-known progress; UI can offer retry.
        }
    }
}
