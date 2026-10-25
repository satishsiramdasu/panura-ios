import SwiftUI

/// Downloads, as a page in the shell — Android's `DownloadsTab`.
///
/// A sheet rather than a section (Android 2767295): a download running is
/// something to see from wherever you are, not a place to go.
///
/// Top to bottom: a search field, a line saying what the saved videos take up
/// and how many are still going (with Cancel all), then one card per video —
/// poster, title, resolution and length, size and date, an inline pause or
/// resume, and a menu of Share, Rename and Delete. Delete always asks.
struct DownloadsPage: View {
    /// Leaves the page, back to the section underneath.
    var onClose: () -> Void
    /// Reopens the page a download came from, for a fresh link.
    var onOpenPage: (String) -> Void

    @ObservedObject private var store = DownloadStore.shared
    @State private var query = ""
    @State private var expired: DownloadEntry?
    @State private var renaming: DownloadEntry?
    @State private var newTitle = ""
    @State private var deleting: DownloadEntry?
    @State private var confirmCancelAll = false

    private var shown: [DownloadEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty { empty } else { content }
            }
            .background(PanuraTheme.background)
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .alert("This link has expired", isPresented: Binding(
            get: { expired != nil }, set: { if !$0 { expired = nil } }
        ), presenting: expired) { entry in
            Button("Open page") {
                onOpenPage(entry.pageURL)
            }
            Button("Delete", role: .destructive) { deleting = entry }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The site no longer accepts this link, or it is invalid. Open the page to get a fresh one — saving again from the same page continues where this stopped.")
        }
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { entry in
            TextField("Title", text: $newTitle)
            Button("Rename") { store.rename(entry.id, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete video?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { entry in
            Button("Delete", role: .destructive) { store.delete(entry.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The saved copy is removed from this device. The page it came from is not affected.")
        }
        .alert("Cancel all downloads?", isPresented: $confirmCancelAll) {
            Button("Cancel all", role: .destructive) { store.cancelAllActive() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This stops and removes every download in progress. Finished videos are kept.")
        }
    }

    // MARK: empty

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

    // MARK: list

    private var content: some View {
        VStack(spacing: 0) {
            searchField
            usageLine
            if shown.isEmpty {
                Text("No results for “\(query)”")
                    .font(.body)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shown) { entry in
                            DownloadRow(
                                entry: entry,
                                onTap: { tap(entry) },
                                onRename: { newTitle = entry.title; renaming = entry },
                                onDelete: { deleting = entry }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            TextField("Search downloads", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(PanuraTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// How much the saved videos take, and how many are still going.
    private var usageLine: some View {
        let active = store.entries.filter { $0.status != .complete }.count
        return HStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Text(StreamProbe.formatSize(store.storageUsedBytes) + " used" + (active > 0 ? " · \(active) active" : ""))
                .font(.footnote.weight(.medium))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Spacer(minLength: 0)
            if active > 0 {
                Button("Cancel all") { confirmCancelAll = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PanuraTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func tap(_ entry: DownloadEntry) {
        switch entry.status {
        case .complete:
            guard let url = entry.playableURL else { return }
            var item = MediaItem(title: entry.title, url: url, isLocal: true)
            item.contentType = entry.isHLS ? "hls" : nil
            item.thumbnailURL = entry.poster.flatMap(URL.init(string:))
            item.thumbnailAlternateURL = entry.posterAlt.flatMap(URL.init(string:))
            if let path = entry.subtitlePath {
                item.subtitles = [SubtitleTrack(
                    url: DownloadStore.root.appendingPathComponent(path),
                    label: entry.subtitleLabel ?? "Subtitles",
                    language: entry.subtitleLanguage ?? ""
                )]
            }
            // The player is the root's cover, and nothing modal is in its way:
            // this is a page, so it stays exactly as it is underneath.
            PlaybackSession.shared.play(item)
        case .expired:
            expired = entry
        default:
            break
        }
    }
}

// MARK: - one card

private struct DownloadRow: View {
    let entry: DownloadEntry
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var store = DownloadStore.shared
    /// Where a stopped row stopped, read from disk: it has no live progress.
    @State private var disk: (done: Int64, total: Int64)?

    private var stopped: Bool { [.paused, .failed, .expired].contains(entry.status) }
    private var running: Bool { entry.status == .downloading || entry.status == .queued }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PosterThumb(
                    url: entry.poster.flatMap(URL.init(string:)),
                    alternate: entry.posterAlt.flatMap(URL.init(string:)),
                    fallback: entry.status == .failed ? "exclamationmark.triangle" : "film",
                    width: 120, height: 68, corner: 10
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.trimmed(entry.title))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(PanuraTheme.onSurface)
                    if !metaLine1.isEmpty {
                        Text(metaLine1)
                            .font(.caption2)
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    }
                    Text(metaLine2)
                        .font(.caption2)
                        .foregroundStyle(entry.status == .failed ? PanuraTheme.error : PanuraTheme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                inlineControl
                menu
            }
            .padding(12)

            if running || (stopped && (disk?.total ?? 0) > 0) {
                progressBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(PanuraTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onTap)
        .task(id: entry.status) {
            disk = stopped ? store.diskProgress(entry) : nil
        }
    }

    // MARK: facts

    /// Resolution and length, as far as they are known.
    private var metaLine1: String {
        var parts: [String] = []
        if let res = entry.resolution, !res.isEmpty { parts.append(res) }
        if entry.durationSeconds > 0 { parts.append(Self.clock(entry.durationSeconds)) }
        // Which audio, so two saves of one page can be told apart.
        if let audio = entry.audioLabel, !audio.isEmpty { parts.append(audio) }
        return parts.joined(separator: " · ")
    }

    /// Size and date once it is saved; how far along while it is not.
    private var metaLine2: String {
        switch entry.status {
        case .complete:
            var parts: [String] = []
            if entry.sizeBytes > 0 { parts.append(StreamProbe.formatSize(entry.sizeBytes)) }
            if let at = entry.completedAt { parts.append(at.formatted(.dateTime.month(.abbreviated).day())) }
            return parts.joined(separator: " · ")
        case .downloading, .queued:
            return progressText(done: entry.done, total: entry.total) ?? "Downloading…"
        case .paused:
            return "Paused" + (stoppedAt.map { " · " + $0 } ?? "")
        case .failed:
            return "Stopped" + (stoppedAt.map { " · " + $0 } ?? "")
        case .expired:
            return "Link expired · tap to fix"
        }
    }

    private var stoppedAt: String? {
        guard let disk, disk.total > 0 else { return nil }
        if entry.isHLS {
            return "\(Int(disk.done * 100 / disk.total))% · \(disk.done) / \(disk.total) parts"
        }
        return "\(Int(disk.done * 100 / disk.total))% · \(StreamProbe.formatSize(max(0, disk.total - disk.done))) left"
    }

    private func progressText(done: Int64, total: Int64) -> String? {
        guard total > 0 else { return nil }
        if entry.isHLS { return "\(done) / \(total) parts" }
        return "\(Int(done * 100 / total))% · \(StreamProbe.formatSize(done)) / \(StreamProbe.formatSize(total))"
    }

    @ViewBuilder
    private var progressBar: some View {
        if running, entry.total <= 0 {
            ProgressView().progressViewStyle(.linear).tint(PanuraTheme.accent)
        } else if running {
            ProgressView(value: entry.progress).tint(PanuraTheme.accent)
        } else if let disk, disk.total > 0 {
            ProgressView(value: Double(disk.done), total: Double(disk.total))
                .tint(PanuraTheme.onSurfaceVariant)
        }
    }

    // MARK: controls

    /// Pause, resume, retry or a fresh link — inline, as Android has them.
    @ViewBuilder
    private var inlineControl: some View {
        switch entry.status {
        case .downloading, .queued:
            control("pause.fill", "Pause") { store.pause(entry.id) }
        case .paused:
            control("play.fill", "Resume") { store.resume(entry.id) }
        case .failed:
            control("arrow.clockwise", "Retry") { store.resume(entry.id) }
        case .expired:
            control("safari", "Get a fresh link") { onTap() }
        case .complete:
            EmptyView()
        }
    }

    private func control(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var menu: some View {
        Menu {
            if entry.status == .complete, !entry.isHLS, let url = entry.playableURL {
                // A single file can be handed over as it is. A saved playlist is a
                // folder of segments with no one file to send; see the note in
                // the commit that added this.
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            if entry.status == .complete {
                Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
    }

    // MARK: formatting

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static let videoExtensions: Set<String> = [
        "ts", "mp4", "mkv", "webm", "m3u8", "mpd", "m4s", "avi", "mov", "flv",
    ]

    private static func trimmed(_ title: String) -> String {
        guard let dot = title.lastIndex(of: "."), dot != title.startIndex,
              videoExtensions.contains(title[title.index(after: dot)...].lowercased())
        else { return title }
        return String(title[..<dot])
    }
}
