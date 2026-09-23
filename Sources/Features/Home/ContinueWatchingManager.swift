import SwiftUI

/// The Manage sheet behind Continue Watching's header.
///
/// The header used to carry one destructive button, so tidying away a single
/// dead link meant throwing out every resume point in the app. A list can do
/// both, and — unlike a menu — it can show what it is about to remove.
///
/// The row is built around the two things the card has no room for: how far
/// through it you are, and how long is left. The horizontal card has to say
/// that in a 3pt bar and a 10pt chip; here both get read properly.
struct ContinueWatchingManager: View {
    var onOpenBrowser: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BrowsingStore.shared

    private var entries: [ResumeEntry] { store.continueWatching }
    private var expired: [ResumeEntry] { store.expiredWatching }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty { empty } else { list }
            }
            .navigationTitle("Continue Watching")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                    dismiss()
                } label: {
                    Label("Remove all \(entries.count)", systemImage: "trash")
                }
            } footer: {
                Text("The videos stay where they are. Only the resume points go.")
            }
        }
    }

    private func row(_ entry: ResumeEntry) -> some View {
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
                } else {
                    // A bar and the two numbers either side of it, which is the
                    // whole question: how far in, and how much is left.
                    ProgressView(value: entry.progress)
                        .tint(PanuraTheme.accent)
                    HStack {
                        Text(Self.clock(entry.position))
                        Spacer(minLength: 8)
                        Text(entry.timeLeftLabel)
                    }
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }

            if entry.isExpired, let page = entry.sourcePage {
                Button {
                    dismiss()
                    onOpenBrowser(page.absoluteString)
                } label: {
                    Label("Visit", systemImage: "safari")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17))
                        .foregroundStyle(PanuraTheme.accent)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                // A plain style, or the row's own tap would fire this too -
                // every button in a List row does, unless it opts out.
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
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
                AsyncImage(url: url) { phase in
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
