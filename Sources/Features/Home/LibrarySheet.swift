import SwiftUI

/// Everything the app remembers about what you watch, in one sheet.
///
/// Three lists that were three screens: what you are part-way through, what you
/// finished, and what you set aside. They answer one question between them —
/// *what was I watching?* — and the answer was in three places reached three
/// different ways, so finding it meant remembering which. One sheet, three
/// tabs, and Home's two entry points land on the tab they name.
///
/// The tab is state, not a parameter, so the segmented control works: arriving
/// sets where it opens, and after that it belongs to whoever is reading.
struct LibrarySheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case watching, history, later
        var id: String { rawValue }

        var label: String {
            switch self {
            case .watching: return "Continue"
            case .history: return "History"
            case .later: return "Later"
            }
        }
    }

    var onOpenBrowser: (String) -> Void

    @State var tab: Tab
    @Environment(\.dismiss) private var dismiss

    init(tab: Tab = .watching, onOpenBrowser: @escaping (String) -> Void) {
        _tab = State(initialValue: tab)
        self.onOpenBrowser = onOpenBrowser
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("List", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                switch tab {
                case .watching:
                    ContinueWatchingList(onOpenBrowser: openBrowser)
                case .history:
                    WatchHistoryList(onOpenBrowser: openBrowser)
                case .later:
                    WatchLaterList(onOpenBrowser: openBrowser)
                }
            }
            .background(PanuraTheme.background)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Every list hands a page to the browser the same way, and the browser is
    /// behind this sheet.
    private func openBrowser(_ address: String) {
        dismiss()
        onOpenBrowser(address)
    }
}

/// What has been watched to the end.
///
/// Deliberately not checked for liveness on appearance. The list runs to
/// hundreds of rows, most of them old, and a sweep would be hundreds of
/// requests to answer a question nobody asked — a stream URL from last month
/// is dead and nobody needs telling. A row finds out when it is pressed, and
/// then says so from that moment on.
struct WatchHistoryList: View {
    var onOpenBrowser: (String) -> Void

    @ObservedObject private var store = BrowsingStore.shared
    @State private var checking: String?

    private var entries: [WatchedEntry] { store.watchedLog }

    var body: some View {
        Group {
            if entries.isEmpty { empty } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    Button { open(entry) } label: { row(entry) }
                        .buttonStyle(.plain)
                        .listRowBackground(PanuraTheme.background)
                }
                .onDelete { offsets in
                    for url in offsets.map({ entries[$0].url }) {
                        store.unmarkWatched(url)
                    }
                }
            } footer: {
                Text("Swipe a row to forget just that one.")
            }

            Section {
                Button(role: .destructive) {
                    store.clearWatchedMarks()
                } label: {
                    Label("Clear history", systemImage: "trash")
                }
            } footer: {
                Text("Clearing history also clears the watched ticks on films and episodes.")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ entry: WatchedEntry) -> some View {
        HStack(spacing: 12) {
            PosterThumb(
                url: entry.poster.flatMap(URL.init(string:)),
                fallback: entry.isLocal ? "film" : "globe",
                width: 112, height: 63, corner: 8
            )
            .opacity(entry.isExpired ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(entry.isExpired ? PanuraTheme.onSurfaceVariant : .primary)
                if entry.isExpired {
                    Label("Link expired", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text(Self.when(entry.finished))
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if checking == entry.url {
                ProgressView()
            } else {
                Image(systemName: entry.isExpired ? "safari" : "arrow.clockwise")
                    .font(.system(size: 16))
                    .foregroundStyle(PanuraTheme.accent)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Watching it again, which is the only thing anybody wants from this list.
    ///
    /// Checked first, like Home's resume cards are: a stream URL found in the
    /// browser a week ago is signed and long dead, and a player that opens and
    /// fails says less than a row that says the link expired and offers the
    /// page it came from.
    private func open(_ entry: WatchedEntry) {
        if entry.isExpired {
            guard let host = URL(string: entry.url)?.host else { return }
            onOpenBrowser("https://" + host + "/")
            return
        }
        guard checking == nil else { return }
        checking = entry.url
        Task {
            let alive = await BrowsingStore.isAlive(entry)
            checking = nil
            if alive {
                PlaybackSession.shared.play(entry.mediaItem)
            } else {
                store.markWatchedExpired(url: entry.url)
            }
        }
    }

    private static func when(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Watched " + formatter.localizedString(for: date, relativeTo: Date())
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Text("Nothing finished yet").font(.headline)
            Text("Videos you watch to the end are listed here, so you can find them again.")
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}
