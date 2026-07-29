import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var playItem: MediaItem?

    var body: some View {
        NavigationStack {
            Group {
                if downloads.jobs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No downloads yet").font(.headline)
                        Text("Videos you save for offline appear here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    List(downloads.jobs) { job in
                        row(job)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Downloads")
        }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0, playlist: playlist(for: $0)) }
    }

    /// Playlist over the finished downloads so next/previous can advance.
    private func playlist(for item: MediaItem) -> PlayerPlaylist? {
        let finished = downloads.jobs.filter { $0.isFinished && $0.localURL != nil }
        guard finished.count > 1,
              let start = finished.firstIndex(where: { $0.localURL == item.url }) else { return nil }
        return PlayerPlaylist(count: finished.count, startIndex: start) { i in
            guard i >= 0, i < finished.count, let url = finished[i].localURL else { return nil }
            return MediaItem(title: finished[i].title, url: url, isLocal: true)
        }
    }

    @ViewBuilder
    private func row(_ job: DownloadJob) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(job.title).lineLimit(1)
                if !job.isFinished {
                    ProgressView(value: job.progress).tint(PanuraTheme.accent)
                }
            }
            Spacer()
            if job.isFinished, let url = job.localURL {
                Button {
                    playItem = MediaItem(title: job.title, url: url, isLocal: true)
                } label: { Image(systemName: "play.circle.fill") }
            }
        }
    }
}
