import SwiftUI

/// Home tab. Mirrors Android's `HomeTab`: address pill header, brand block with
/// version + action links, then Shortcuts · Continue Watching · Most Visited.
struct HomeView: View {
    /// Hands a raw address-bar string (URL or search terms) to the Browser tab.
    var onOpenBrowser: (String) -> Void
    /// Home is the hub for everything without a seat in the bottom bar, so the
    /// Options grid needs a way to send you there.
    var onOpenSection: (AppDestination) -> Void = { _ in }

    @ObservedObject private var store = BrowsingStore.shared

    @State private var showAddress = false
    @State private var showShortcutsSheet = false
    @State private var showMostVisitedSheet = false
    @State private var editingShortcut: SiteEntry?
    @State private var playItem: MediaItem?
    @State private var confirmClearHistory = false
    @State private var showReport = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    brandBlock
                    shortcutsSection
                    if !store.continueWatching.isEmpty { continueWatchingSection }
                    mostVisitedSection
                    optionsSection
                }
                .padding(.vertical, 20)
            }
            .safeAreaInset(edge: .top) { header }
            .navigationBarHidden(true)
        }
        .fullScreenCover(isPresented: $showAddress) {
            AddressScreen(
                onNavigate: { text in
                    showAddress = false
                    onOpenBrowser(text)
                },
                onDismiss: { showAddress = false }
            )
        }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0) }
        .sheet(isPresented: $showShortcutsSheet) { shortcutsSheet }
        .sheet(isPresented: $showMostVisitedSheet) { mostVisitedSheet }
        .sheet(item: $editingShortcut) { ShortcutEditor(entry: $0) }
        .sheet(isPresented: $showReport) { ReportIssueSheet(source: "home") }
        .confirmationDialog(
            "Clear browsing history?",
            isPresented: $confirmClearHistory,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Most Visited and recent pages are removed. Shortcuts and Continue Watching are kept.")
        }
    }

    // MARK: options

    /// The destinations and housekeeping actions that have no seat in the bar.
    /// Home is where they live now, which is what lets the bar stay down to the
    /// three places you actually switch between.
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Options")
            HStack(spacing: 10) {
                optionTile("Settings", systemImage: "gearshape.fill") { onOpenSection(.settings) }
                optionTile("Network Stream", systemImage: "link") { onOpenSection(.stream) }
                optionTile("Report Issue", systemImage: "ladybug") { showReport = true }
                optionTile("Clear History", systemImage: "trash") { confirmClearHistory = true }
            }
            .padding(.horizontal, 16)
        }
    }

    private func optionTile(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(PanuraTheme.accent)
                Text(title)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: header — address pill, same shape as the browser's top bar

    private var header: some View {
        PanuraHeader {
            AddressPill(
                title: "",
                url: "",
                placeholder: "Search Google or enter website",
                background: Color(.secondarySystemBackground),
                onTap: { showAddress = true },
                leading: { EmptyView() },
                trailing: { EmptyView() }
            )
        }
    }

    // MARK: brand + action links

    private var brandBlock: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    Text("Panura").font(.largeTitle.bold())
                    if !appVersion.isEmpty {
                        Text("v\(appVersion)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(PanuraTheme.accent)
                    }
                }
                Text("WEB VIDEO PLAYER")
                    .font(.caption2.weight(.medium))
                    .tracking(2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                ShareLink(
                    item: URL(string: "https://panura.app")!,
                    message: Text("Panura Player — browse, play, download & cast web videos.")
                ) {
                    linkLabel("Share App", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIApplication.shared.open(URL(string: "https://t.me/panura_player")!)
                } label: {
                    linkLabel("Telegram", systemImage: "paperplane.fill")
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func linkLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PanuraTheme.accent)
    }

    // MARK: shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Shortcuts", showAll: !store.shortcuts.isEmpty) {
                showShortcutsSheet = true
            }
            if store.shortcuts.isEmpty {
                emptyHint("Add any website as a shortcut to show here.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.shortcuts.prefix(10)) { item in
                            ShortcutTile(entry: item)
                                .onTapGesture { onOpenBrowser(item.url) }
                                .contextMenu {
                                    Button { editingShortcut = item } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        store.removeShortcut(url: item.url)
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: continue watching

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Continue Watching")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.continueWatching) { entry in
                        ContinueWatchingCard(entry: entry)
                            .onTapGesture { playItem = entry.mediaItem }
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.removeWatching(url: entry.url)
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: most visited

    private var mostVisitedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Most Visited", showAll: !store.history.isEmpty) {
                showMostVisitedSheet = true
            }
            if store.history.isEmpty {
                emptyHint("Sites you visit often will appear here.")
            } else {
                // Two fixed rows scrolling sideways — Android's LazyHorizontalGrid.
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(44)), GridItem(.fixed(44))], spacing: 8) {
                        ForEach(store.mostVisited.prefix(10)) { item in
                            MostVisitedTile(entry: item)
                                .onTapGesture { onOpenBrowser(item.url) }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        // Tiles come from the host tally, not
                                        // from history — removing the row would
                                        // leave the tile sitting there.
                                        store.removeHostVisit(host: item.host)
                                    } label: { Label("Remove", systemImage: "trash") }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 96)
            }
        }
    }

    // MARK: sheets

    private var shortcutsSheet: some View {
        NavigationStack {
            List {
                ForEach(store.shortcuts) { item in
                    Button {
                        showShortcutsSheet = false
                        onOpenBrowser(item.url)
                    } label: { SiteRow(entry: item) }
                        .buttonStyle(.plain)
                }
                .onDelete { store.removeShortcut(url: store.shortcuts[$0.first ?? 0].url) }
                .onMove { store.moveShortcuts(from: $0, to: $1) }
            }
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showShortcutsSheet = false }
                }
            }
        }
    }

    private var mostVisitedSheet: some View {
        NavigationStack {
            List {
                ForEach(store.mostVisited) { item in
                    Button {
                        showMostVisitedSheet = false
                        onOpenBrowser(item.url)
                    } label: { SiteRow(entry: item) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.removeHostVisit(host: store.mostVisited[index].host)
                    }
                }
            }
            .navigationTitle("Most Visited")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear all") { store.clearHistory() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showMostVisitedSheet = false }
                }
            }
        }
    }

    // MARK: bits

    private func sectionHeader(
        _ title: String,
        showAll: Bool = false,
        action: @escaping () -> Void = {}
    ) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if showAll {
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text("Show all").font(.caption)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(PanuraTheme.accent)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }
}

// MARK: - tiles

private struct ShortcutTile: View {
    let entry: SiteEntry

    var body: some View {
        VStack(spacing: 4) {
            Favicon(entry: entry, size: 30)
                .padding(13)
                .background(Color(.secondarySystemBackground), in: Circle())
            Text(entry.title)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
    }
}

private struct MostVisitedTile: View {
    let entry: SiteEntry

    var body: some View {
        HStack(spacing: 8) {
            Favicon(entry: entry, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.caption).lineLimit(1)
                Text(entry.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: 170, height: 44)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

private struct ContinueWatchingCard: View {
    let entry: ResumeEntry

    /// Decoded once when the card appears, off the main thread. A computed
    /// property would re-read the file on every layout pass, and the row is a
    /// horizontal scroller. The file lives in Caches and may be gone, so a
    /// failed load is ordinary and simply leaves the glyph in place.
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 140, height: 90)
                    .clipped()
            } else {
                Image(systemName: entry.isLocal ? "film.fill" : "link")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Image(systemName: "play.circle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if entry.remainingSeconds > 0 {
                Text(entry.timeLeftLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            VStack(spacing: 0) {
                if entry.progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.35))
                            Rectangle()
                                .fill(PanuraTheme.accent)
                                .frame(width: geo.size.width * entry.progress)
                        }
                    }
                    .frame(height: 3)
                }
                Text(entry.title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground).opacity(0.75))
            }
        }
        .frame(width: 140, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .task(id: entry.thumbnailPath) {
            guard let path = entry.thumbnailPath else { thumbnail = nil; return }
            thumbnail = await Task.detached { UIImage(contentsOfFile: path) }.value
        }
    }
}

/// Title/URL editor for a pinned shortcut.
private struct ShortcutEditor: View {
    let entry: SiteEntry

    @ObservedObject private var store = BrowsingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var url: String

    init(entry: SiteEntry) {
        self.entry = entry
        _title = State(initialValue: entry.title)
        _url = State(initialValue: entry.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("URL", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.updateShortcut(
                            original: entry.url,
                            title: title.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces)
                        )
                        dismiss()
                    }
                    .disabled(title.isEmpty || url.isEmpty)
                }
            }
        }
    }
}
