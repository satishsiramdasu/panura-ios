import SwiftUI
import Photos
import AVFoundation

/// The Videos tab, with what Android's media picker offers, on what the Photos
/// library can actually answer: albums in place of folders, search, a sort menu,
/// selection with play/share/delete, and an info sheet.
///
/// Two of Android's actions are missing for good: renaming an asset is not
/// something the Photos framework permits, and there is no filesystem path to
/// show — an asset has an identifier, not a location.
struct LocalVideosView: View {
    @StateObject private var model = LocalVideosModel()
    @State private var playItem: MediaItem?
    @State private var playIndex = 0
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var infoItem: LocalVideoAsset?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var showAlbums = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .needsPermission:
                    permissionPrompt
                case .empty:
                    ContentUnavailableViewCompat(
                        title: "No videos", systemImage: "film",
                        description: "Videos in your library will show up here."
                    )
                case .loaded:
                    content
                case .loading:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanuraTheme.background)
            .safeAreaInset(edge: .top) { PanuraHeader("Videos") }
            .navigationBarHidden(true)
        }
        .task { await model.load() }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0, playlist: localPlaylist()) }
        .sheet(item: $infoItem) { infoSheet($0) }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareURLs) }
        .sheet(isPresented: $showAlbums) { albumsSheet }
    }

    // MARK: grid

    private var content: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if selecting { toggle(item) } else { play(item, at: index) }
                        } label: {
                            VideoCell(item: item, selected: selection.contains(item.id), selecting: selecting)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { infoItem = item } label: {
                                Label("Info", systemImage: "info.circle")
                            }
                            Button { share([item]) } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                Task { await delete([item]) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(12)
            }
            if selecting, !selection.isEmpty { selectionBar }
        }
    }

    /// Search, sort and the album picker, in one row above the grid — Android
    /// puts the same three in its picker's top bar.
    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    TextField("Search videos", text: $model.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(PanuraTheme.surfaceVariant, in: Capsule())

                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(LocalVideosModel.SortOrder.allCases) { order in
                            Label(order.rawValue, systemImage: order.icon).tag(order)
                        }
                    }
                } label: {
                    toolbarGlyph("arrow.up.arrow.down")
                }

                Button { showAlbums = true } label: { toolbarGlyph("folder") }
                    .buttonStyle(.plain)

                Button {
                    selecting.toggle()
                    if !selecting { selection.removeAll() }
                } label: {
                    toolbarGlyph(selecting ? "xmark" : "checkmark.circle", active: selecting)
                }
                .buttonStyle(.plain)
            }

            if let album = model.album {
                // Says which album is being shown, and gets out of it — without
                // this the grid silently holds a subset of the library.
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.caption2)
                    Text(album.title).font(.caption.weight(.medium)).lineLimit(1)
                    Button {
                        model.album = nil
                        Task { await model.reload() }
                    } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain)
                }
                .foregroundStyle(PanuraTheme.accent)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(PanuraTheme.accentSoft, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func toolbarGlyph(_ icon: String, active: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 38, height: 38)
            .background(
                Circle().fill(active ? PanuraTheme.accentSoft : PanuraTheme.surfaceVariant)
            )
            .foregroundStyle(active ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
    }

    /// What Android's selection sheet holds, minus rename.
    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text("\(selection.count) selected")
                .font(.footnote.weight(.medium))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Spacer(minLength: 4)
            Button {
                selection = Set(model.visible.map(\.id))
            } label: { Image(systemName: "checkmark.circle.fill") }
            Button { share(selected()) } label: { Image(systemName: "square.and.arrow.up") }
            Button(role: .destructive) {
                Task { await delete(selected()) }
            } label: { Image(systemName: "trash") }
                .foregroundStyle(PanuraTheme.error)
            Button {
                guard let first = selected().first,
                      let index = model.visible.firstIndex(where: { $0.id == first.id })
                else { return }
                play(first, at: index)
            } label: { Image(systemName: "play.fill") }
        }
        .font(.system(size: 17))
        .foregroundStyle(PanuraTheme.accent)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(PanuraTheme.surfaceContainer)
    }

    // MARK: sheets

    private var albumsSheet: some View {
        NavigationStack {
            List {
                Button {
                    model.album = nil
                    showAlbums = false
                    Task { await model.reload() }
                } label: {
                    Label("All videos", systemImage: "square.grid.2x2")
                }
                ForEach(model.albums) { album in
                    Button {
                        model.album = album
                        showAlbums = false
                        Task { await model.reload() }
                    } label: {
                        HStack {
                            Label(album.title, systemImage: "folder")
                            Spacer()
                            Text("\(album.count)")
                                .font(.footnote)
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PanuraTheme.background)
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showAlbums = false }
                }
            }
        }
    }

    private func infoSheet(_ item: LocalVideoAsset) -> some View {
        NavigationStack {
            List {
                infoRow("Name", item.title)
                infoRow("Duration", item.durationLabel)
                infoRow("Resolution", item.resolutionLabel)
                if let size = model.fileSize(for: item) { infoRow("Size", size) }
                infoRow("Created", item.created.formatted(date: .abbreviated, time: .shortened))
            }
            .scrollContentBackground(.hidden)
            .background(PanuraTheme.background)
            .navigationTitle("Video info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { infoItem = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.footnote).foregroundStyle(PanuraTheme.onSurfaceVariant)
            Spacer()
            Text(value).font(.footnote).multilineTextAlignment(.trailing)
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
            Text("Allow access to your videos").font(.headline)
            Button("Grant Access") { Task { await model.requestAccess() } }
                .buttonStyle(.borderedProminent)
                .tint(PanuraTheme.accent)
        }
    }

    // MARK: actions

    private func selected() -> [LocalVideoAsset] {
        model.visible.filter { selection.contains($0.id) }
    }

    private func toggle(_ item: LocalVideoAsset) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else { selection.insert(item.id) }
    }

    private func share(_ items: [LocalVideoAsset]) {
        Task {
            var urls: [URL] = []
            for item in items {
                if let url = await model.resolveURL(for: item) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            shareURLs = urls
            showShare = true
        }
    }

    private func delete(_ items: [LocalVideoAsset]) async {
        guard !items.isEmpty else { return }
        let removed = await model.delete(items)
        if removed {
            selection.removeAll()
            selecting = false
            await model.reload()
        }
    }

    /// Playlist over what is on screen, so the player's next/previous walks the
    /// same order the grid is in — including the search and sort in force.
    /// URLs resolve lazily; only the item being played is resolved.
    private func localPlaylist() -> PlayerPlaylist? {
        let items = model.visible
        guard items.count > 1 else { return nil }
        return PlayerPlaylist(count: items.count, startIndex: playIndex) { i in
            guard i >= 0, i < items.count,
                  let url = await model.resolveURL(for: items[i]) else { return nil }
            return MediaItem(title: items[i].title, url: url, isLocal: true)
        }
    }

    private func play(_ asset: LocalVideoAsset, at index: Int) {
        Task {
            if let url = await model.resolveURL(for: asset) {
                playIndex = index
                playItem = MediaItem(title: asset.title, url: url, isLocal: true)
            }
        }
    }
}

private struct VideoCell: View {
    let item: LocalVideoAsset
    var selected = false
    var selecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(PanuraTheme.surfaceVariant)
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                }
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // How long it is, where a thumbnail always carries it.
                Text(item.durationLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(5)

                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? PanuraTheme.accent : .white)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(PanuraTheme.accent, lineWidth: 2)
                }
            }
            Text(item.title).font(.caption).lineLimit(1)
        }
    }
}

/// Back-compat wrapper so this compiles on iOS 16 (ContentUnavailableView is iOS 17+).
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Text(title).font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
