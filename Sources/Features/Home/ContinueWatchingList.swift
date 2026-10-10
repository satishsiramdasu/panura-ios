import SwiftUI

/// What is part-way through — the first tab of `LibrarySheet`.
///
/// It used to be a sheet of its own, opened from Continue Watching's header,
/// and the header before that carried one destructive button, so tidying away
/// a single dead link meant throwing out every resume point in the app. A list
/// can do both, and — unlike a menu — it can show what it is about to remove.
///
/// The row is built around the two things the card has no room for: how far
/// through it you are, and how long is left. The horizontal card has to say
/// that in a 3pt bar and a 10pt chip; here both get read properly.
struct ContinueWatchingList: View {
    var onOpenBrowser: (String) -> Void
    var onPlay: (MediaItem, PlayerPlaylist?) -> Void

    @ObservedObject private var store = BrowsingStore.shared

    private var entries: [ResumeEntry] { store.continueWatching }
    private var expired: [ResumeEntry] { store.expiredWatching }

    var body: some View {
        Group {
            if entries.isEmpty { empty } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                ForEach(entries) { entry in row(entry) }
                    .onDelete { offsets in
                        for index in offsets {
                            store.removeWatching(url: entries[index].url)
                        }
                    }
            } footer: {
                Text("Swipe a row to remove just that one.")
            }

            Section {
                // Only when there is something to do. A button that removes
                // nothing is a button that teaches people not to read buttons.
                if !expired.isEmpty {
                    Button(role: .destructive) {
                        store.removeExpiredWatching()
                    } label: {
                        Label(
                            "Remove \(expired.count) expired",
                            systemImage: "link.badge.plus"
                        )
                    }
                }
                Button(role: .destructive) {
                    store.clearWatching()
                } label: {
                    Label("Remove all \(entries.count)", systemImage: "trash")
                }
            } footer: {
                Text("The videos stay where they are. Only the resume points go.")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// A row opens what it shows: the video if the link is good, the page it
    /// came from if it is not.
    ///
    /// It used to open nothing at all. A list of things you are part-way
    /// through, every row of which is inert, is a list that answers a question
    /// nobody was asking — the reason to look at it is to carry on with one of
    /// them.
    private func row(_ entry: ResumeEntry) -> some View {
        Button { open(entry) } label: {
            HStack(spacing: 12) {
                ResumeThumb(entry: entry)

                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(entry.isExpired ? PanuraTheme.onSurfaceVariant : .primary)

                    if entry.isExpired {
                        Label("Link expired", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if let left = entry.timeLeftLabel {
                        // A bar and the two numbers either side of it, which is
                        // the whole question: how far in, and how much is left.
                        ProgressView(value: entry.progress)
                            .tint(PanuraTheme.accent)
                        HStack {
                            Text(Self.clock(entry.position))
                            Spacer(minLength: 8)
                            Text(left)
                        }
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    } else {
                        // No duration: a live channel, or something closed
                        // before the engine had parsed one. A progress bar
                        // here would be a bar that is always empty, under two
                        // numbers that are always zero.
                        Text(Self.opened(entry.updated))
                            .font(.caption2)
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: entry.isExpired ? "safari" : "play.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(PanuraTheme.accent)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Play it, or — for a link that has died — go back to where it came
    /// from. Either way the sheet closes around it: the player arrives as a
    /// full-screen cover from the root view, and a sheet presented by that
    /// same view is in its way. `LibrarySheet.play` does the closing.
    private func open(_ entry: ResumeEntry) {
        if entry.isExpired {
            guard let page = entry.sourcePage else { return }
            onOpenBrowser(page.absoluteString)
            return
        }
        onPlay(entry.mediaItem, nil)
    }

    /// "Opened 2 hours ago", for an entry with no duration to report.
    private static func opened(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Opened " + formatter.localizedString(for: date, relativeTo: Date())
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .font(.largeTitle)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Text("Nothing to resume").font(.headline)
            Text("Videos you stop part-way through show up here.")
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    /// `8:07` · `1:12:40`. Hours only when there are any.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}

/// The list's small picture: poster first, grabbed frame second, glyph last —
/// the same order the card uses, for the same reason.
private struct ResumeThumb: View {
    let entry: ResumeEntry

    @State private var frame: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(PanuraTheme.surfaceVariant)

            if let url = entry.poster.flatMap(URL.init(string:)) {
                RemoteImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: fallback
                    default: Color.clear
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 78, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(entry.isExpired ? 0.45 : 1)
        .task(id: entry.thumbnailPath) {
            guard let path = entry.thumbnailPath else { frame = nil; return }
            frame = await Task.detached { UIImage(contentsOfFile: path) }.value
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if let frame {
            Image(uiImage: frame).resizable().scaledToFill()
        } else {
            Image(systemName: entry.isLocal ? "film.fill" : "link")
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
    }
}
