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

    private let gridColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    private let listColumns = [GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .needsPermission:
                    permissionPrompt
                // Empty and loaded are the same screen. An empty album used to
                // replace the whole view, toolbar included, which took away the
                // album chip and the albums button — the only ways back out of
                // the album that was empty.
                case .empty, .loaded:
                    content
                case .loading:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanuraTheme.background)
            .safeAreaInset(edge: .top, spacing: 0) { PanuraHeader("Videos") }
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
            if model.visible.isEmpty {
                ContentUnavailableViewCompat(
                    title: emptyTitle, systemImage: "film", description: emptyMessage
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // One `LazyVGrid` for both: a list is a grid of one column,
                    // and sharing the container keeps scroll position and
                    // selection across a switch instead of rebuilding the screen.
                    LazyVGrid(columns: model.layout == .grid ? gridColumns : listColumns, spacing: 12) {
                        ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, item in
                            cell(item, at: index)
                        }
                    }
                    .padding(12)
                }
            }
            // Shown for the whole of selection mode, empty selection included:
            // it is what says the mode is on, and what gets out of it.
            if selecting { selectionBar }
        }
        .overlay(alignment: .bottom) { statusBanner }
    }

    /// Says which of the three empty cases this is — a filter that matched
    /// nothing reads very differently from a library with no videos in it.
    private var emptyTitle: String {
        if !model.search.trimmingCharacters(in: .whitespaces).isEmpty { return "No matches" }
        return model.album == nil ? "No videos" : "Empty album"
    }

    private var emptyMessage: String {
        if !model.search.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Nothing here is called that."
        }
        return model.album == nil
            ? "Videos in your library will show up here."
            : "This album has no videos in it."
    }

    @ViewBuilder
    private func cell(_ item: LocalVideoAsset, at index: Int) -> some View {
        Group {
            if model.layout == .grid {
                VideoCell(item: item, selected: selection.contains(item.id), selecting: selecting)
            } else {
                VideoRow(item: item, selected: selection.contains(item.id), selecting: selecting)
            }
        }
        // The whole cell, thumbnail and caption alike, takes the tap — a
        // Button's label only accepts one where it actually painted something.
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(item) } else { play(item, at: index) }
        }
        // Press and hold opens this. Android starts selection on the same
        // gesture, but on iOS it belongs to the context menu, so selection is
        // the menu's first entry instead — reachable from a video rather than
        // only from one glyph in the toolbar.
        .contextMenu {
            Button {
                selecting = true
                toggle(item)
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
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

                Button {
                    model.layout = model.layout.next
                } label: {
                    toolbarGlyph(model.layout.next.icon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    model.layout == .grid ? "Switch to list" : "Switch to grid"
                )

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
                        endSelection()
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
            .contentShape(Circle())
    }

    /// What Android's selection sheet holds, minus rename.
    ///
    /// The actions grey out on an empty selection rather than disappearing, so
    /// the bar keeps its shape as videos are picked, and it always offers the
    /// way out of the mode.
    private var selectionBar: some View {
        let picked = selected()
        let all = model.visible
        let everything = !all.isEmpty && picked.count == all.count
        return HStack(spacing: 14) {
            Button {
                selecting = false
                selection.removeAll()
            } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)

            Text(picked.isEmpty ? "Select videos" : "\(picked.count) selected")
                .font(.footnote.weight(.medium))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Toggles: a second press on a full selection clears it, which is
            // the only quick way back to none.
            Button {
                selection = everything ? [] : Set(all.map(\.id))
            } label: {
                Image(systemName: everything ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(.plain)

            Button { share(picked) } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty)

            Button {
                guard let first = picked.first,
                      let index = all.firstIndex(where: { $0.id == first.id })
                else { return }
                play(first, at: index)
            } label: { Image(systemName: "play.fill") }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty)

            Button {
                Task { await delete(picked) }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(picked.isEmpty ? PanuraTheme.onSurfaceVariant : PanuraTheme.error)
                .disabled(picked.isEmpty)
        }
        .font(.system(size: 17))
        .foregroundStyle(PanuraTheme.accent)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(PanuraTheme.surfaceContainer)
    }

    /// Says a video is being fetched, or why one could not be. Getting a file
    /// out of the library takes a moment — an iCloud video has to come down
    /// first — and a tap that appears to do nothing is indistinguishable from a
    /// tap that was never registered.
    @ViewBuilder
    private var statusBanner: some View {
        if let preparing = model.preparing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Opening \(preparing)").font(.footnote).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(PanuraTheme.surfaceContainerHigh, in: Capsule())
            .padding(.bottom, 16)
        } else if let error = model.error {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PanuraTheme.error)
                Text(error).font(.footnote).lineLimit(2)
                Button { model.error = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(PanuraTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: sheets

    private var albumsSheet: some View {
        NavigationStack {
            List {
                Button {
                    model.album = nil
                    showAlbums = false
                    endSelection()
                    Task { await model.reload() }
                } label: {
                    Label("All videos", systemImage: "square.grid.2x2")
                }
                ForEach(model.albums) { album in
                    Button {
                        model.album = album
                        showAlbums = false
                        endSelection()
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

    /// Leaves selection mode. Called whenever the grid's contents change under
    /// it: a selection is a set of ids, and ids from the album you just left
    /// mean nothing in the one you arrived at.
    private func endSelection() {
        selecting = false
        selection.removeAll()
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

/// The list shape: a wide thumbnail on the left, then the name and what is
/// known about the file. Android's `VideoListItem` — 80pt tall, 120pt of
/// thumbnail — because a list earns its place by having room for a long
/// filename and the details a grid caption cannot hold.
private struct VideoRow: View {
    let item: LocalVideoAsset
    var selected = false
    var selecting = false

    var body: some View {
        HStack(spacing: 10) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
            }

            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(PanuraTheme.surfaceVariant)
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                }
                Text(item.durationLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(4)
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(item.resolutionLabel)
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(selected ? PanuraTheme.accentSoft : PanuraTheme.surfaceContainer)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(PanuraTheme.accent, lineWidth: 1)
            }
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
