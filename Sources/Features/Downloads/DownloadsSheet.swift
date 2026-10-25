import SwiftUI

/// Downloads, as a sheet — the Library's shape, opened from the header.
///
/// A sheet rather than a section (Android 2767295): a download running is
/// something to see from wherever you are, not a place to go.
struct DownloadsSheet: View {
    /// Reopens the page a download came from, for a fresh link.
    var onOpenPage: (String) -> Void

    @ObservedObject private var store = DownloadStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var expired: DownloadEntry?
    @State private var renaming: DownloadEntry?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty { empty } else { list }
            }
            .background(PanuraTheme.background)
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetCloseButton { dismiss() }
                }
            }
        }
        .onAppear { store.unseen = false }
        .alert("This link has expired", isPresented: Binding(
            get: { expired != nil }, set: { if !$0 { expired = nil } }
        ), presenting: expired) { entry in
            Button("Open page") {
                let page = entry.pageURL
                dismiss()
                onOpenPage(page)
            }
            Button("Delete", role: .destructive) { store.delete(entry.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The site no longer accepts this link, or it is invalid. Open the page to get a fresh one — saving again from the same page continues where this stopped.")
        }
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { entry in
            TextField("Title", text: $newTitle)
            Button("Save") { store.rename(entry.id, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 72, height: 72)
                .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("No downloads yet").font(.headline)
            Text("Save a video from the found-video sheet to watch it offline.")
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(store.entries) { entry in
                Button { tap(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
                    .listRowBackground(PanuraTheme.background)
                    .swipeActions {
                        Button(role: .destructive) { store.delete(entry.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button {
                            newTitle = entry.title
                            renaming = entry
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { store.delete(entry.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func tap(_ entry: DownloadEntry) {
        switch entry.status {
        case .complete:
            guard let url = entry.playableURL else { return }
            var item = MediaItem(title: entry.title, url: url, isLocal: true)
            item.contentType = entry.isHLS ? "hls" : nil
            item.thumbnailURL = entry.poster.flatMap(URL.init(string:))
            PlaybackSession.shared.playWhenDismissed(item)
            dismiss()
        case .downloading, .queued:
            store.pause(entry.id)
        case .paused, .failed:
            store.resume(entry.id)
        case .expired:
            expired = entry
        }
    }

    private func row(_ entry: DownloadEntry) -> some View {
        HStack(spacing: 12) {
            PosterThumb(
                url: entry.poster.flatMap(URL.init(string:)),
                fallback: "film", width: 120, height: 68, corner: 8
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                status(entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing(entry)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func status(_ entry: DownloadEntry) -> some View {
        switch entry.status {
        case .complete:
            Text(StreamProbe.formatSize(entry.sizeBytes))
                .font(.caption).foregroundStyle(PanuraTheme.onSurfaceVariant)
        case .downloading, .queued:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: entry.progress)
                    .tint(PanuraTheme.accent)
                Text(progressText(done: entry.done, total: entry.total, hls: entry.isHLS))
                    .font(.caption2).foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
        case .paused, .failed:
            // Where it stopped, read from disk — a stopped row has no live
            // progress, and "Paused" alone does not say how much is left.
            let disk = store.diskProgress(entry)
            VStack(alignment: .leading, spacing: 3) {
                if disk.total > 0 {
                    ProgressView(value: Double(disk.done), total: Double(disk.total))
                        .tint(PanuraTheme.onSurfaceVariant)
                }
                Text((entry.status == .failed ? "Stopped · " : "Paused · ")
                     + progressText(done: disk.done, total: disk.total, hls: entry.isHLS))
                    .font(.caption2).foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
        case .expired:
            Text("Link expired — tap to open the page")
                .font(.caption).foregroundStyle(PanuraTheme.error)
        }
    }

    private func progressText(done: Int64, total: Int64, hls: Bool) -> String {
        guard total > 0 else { return hls ? "\(done) parts" : StreamProbe.formatSize(done) }
        if hls { return "\(done) of \(total) parts · \(total - done) left" }
        return "\(StreamProbe.formatSize(done)) of \(StreamProbe.formatSize(total)) · \(StreamProbe.formatSize(total - done)) left"
    }

    @ViewBuilder
    private func trailing(_ entry: DownloadEntry) -> some View {
        let icon: String? = {
            switch entry.status {
            case .downloading, .queued: return "pause.fill"
            case .paused, .failed: return "arrow.clockwise"
            case .expired: return "safari"
            case .complete: return nil
            }
        }()
        if let icon {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 36, height: 36)
                .background(PanuraTheme.surfaceContainerHigh, in: Circle())
        }
    }
}
