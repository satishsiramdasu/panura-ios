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
        .fullScreenCover(item: $playItem) { PlayerView(item: $0) }
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
