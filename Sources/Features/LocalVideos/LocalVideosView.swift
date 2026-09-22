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
    @State private var playIndex = 0
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var infoItem: LocalVideoAsset?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var showAlbums = false

    @AppStorage("mark_last_played") private var markLastPlayed = true
    @AppStorage("show_extension") private var showExtension = true
    /// Read once per appearance rather than per cell — it only changes when this
    /// screen is the one starting playback, and that closes the screen.
    @State private var lastPlayedID: String?
    @ObservedObject private var panuraCast = PanuraCastManager.shared
    @ObservedObject private var chromecast = CastManager.shared
    /// The video waiting on "here or on TV?", with where it sits in the list so
    /// playing on the phone still gets its playlist.
    @State private var pendingChoice: (asset: LocalVideoAsset, index: Int)?
    /// Sent to the TV, waiting on "replace what is playing?".
    @State private var pendingReplace: LocalVideoAsset?
    /// A whole selection waiting on "here or on TV?".
    @State private var pendingBatch: [LocalVideoAsset]?

    /// One line, said once — casting gives no other sign from this screen.
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

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
            // Search and the three controls belong to the bar, not to the
            // grid. Under it with no space they read as one dark mass glued to
            // the header; in it, on the bar's own surface and closed by a
            // hairline, they read as the bar they are — and the grid gets a
            // clean edge to scroll under.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    PanuraHeader("Videos")
                    if showsToolbar {
                        toolbar
                        Divider()
                    }
                }
                .background(PanuraTheme.surfaceContainer)
            }
            .navigationBarHidden(true)
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(PanuraTheme.surfaceContainerHigh, in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
        }
        .task {
            lastPlayedID = LocalVideosModel.lastPlayedID
            await model.load()
        }
        .sheet(item: $infoItem) { infoSheet($0) }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareURLs) }
        .sheet(isPresented: $showAlbums) { albumsSheet }
        // A selection has no cell to point at, so unlike the per-video dialogs
        // this one belongs to the screen.
        .confirmationDialog(
            "Play these on the TV?",
            isPresented: Binding(
                get: { pendingBatch != nil },
                set: { if !$0 { pendingBatch = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tvName.map { "Play on " + $0 } ?? "Play on TV") {
                let picked = pendingBatch ?? []
                pendingBatch = nil
                cast(picked)
                selecting = false
                selection.removeAll()
            }
            Button("Add to the queue") {
                let picked = pendingBatch ?? []
                pendingBatch = nil
                queue(picked)
                selecting = false
                selection.removeAll()
            }
            Button("Play on this phone") {
                let picked = pendingBatch ?? []
                pendingBatch = nil
                if let first = picked.first,
                   let index = model.visible.firstIndex(where: { $0.id == first.id }) {
                    play(first, at: index)
                }
            }
            Button("Cancel", role: .cancel) { pendingBatch = nil }
        } message: {
            Text(pendingBatch.map { picked in
                picked.count == 1
                    ? "1 video, and a TV is connected."
                    : "\(picked.count) videos, and a TV is connected."
            } ?? "")
        }
    }

    // MARK: grid

    /// The toolbar has nothing to act on until the library is readable.
    private var showsToolbar: Bool {
        switch model.state {
        case .empty, .loaded: return true
        default: return false
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
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

    private func cell(_ item: LocalVideoAsset, at index: Int) -> some View {
        let lastPlayed = markLastPlayed && lastPlayedID == item.id
        return Group {
            if model.layout == .grid {
                VideoCell(
                    item: item, title: item.displayTitle(showExtension: showExtension),
                    selected: selection.contains(item.id), selecting: selecting,
                    lastPlayed: lastPlayed
                )
            } else {
                VideoRow(
                    item: item, title: item.displayTitle(showExtension: showExtension),
                    size: model.sizes[item.id],
                    selected: selection.contains(item.id), selecting: selecting,
                    lastPlayed: lastPlayed
                )
                // Only for rows that get drawn, and only once each.
                .task { model.loadSize(for: item) }
            }
        }
        // The whole cell, thumbnail and caption alike, takes the tap — a
        // Button's label only accepts one where it actually painted something.
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(item) } else { playOrAsk(item, at: index) }
        }
        // Press and hold opens this. Android starts selection on the same
        // gesture, but on iOS it belongs to the context menu, so selection is
        // the menu's first entry instead — reachable from a video rather than
        // only from one glyph in the toolbar.
        .contextMenu {
            Button {
                castOrAsk([item])
            } label: {
                Label(tvName.map { "Play on " + $0 } ?? "Play on TV", systemImage: "tv")
            }
            Button {
                selecting = true
                toggle(item)
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            // The identifier, not a file path: Photos hands out paths that
            // stop working, and an iCloud video may have no local file at all
            // until the moment it is played.
            Button {
                BrowsingStore.shared.addWatchLater(
                    url: item.id,
                    title: item.title,
                    isLocal: true
                )
            } label: {
                Label("Watch Later", systemImage: "clock")
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
        // Both dialogs hang off the cell, not off the screen. A
        // `confirmationDialog` points at the view it is attached to, so one
        // mounted on the whole grid grew an arrow aimed at the middle of the
        // list — at whichever video happened to be there, not the one that was
        // pressed. Per-cell bindings mean only the pressed video ever presents,
        // and the arrow lands on it.
        .confirmationDialog(
            "Play here or on TV?",
            isPresented: choosing(item),
            titleVisibility: .visible
        ) {
            Button(tvName.map { "Play on " + $0 } ?? "Play on TV") {
                pendingChoice = nil
                castOrAsk([item])
            }
            Button("Play on this phone") {
                pendingChoice = nil
                play(item, at: index)
            }
            Button("Cancel", role: .cancel) { pendingChoice = nil }
        } message: {
            Text("\(item.displayTitle(showExtension: showExtension)) — a TV is connected.")
        }
        .confirmationDialog(
            "Replace what is on the TV?",
            isPresented: replacing(item),
            titleVisibility: .visible
        ) {
            Button("Replace what is playing") {
                pendingReplace = nil
                cast([item])
            }
            Button("Add to the queue") {
                pendingReplace = nil
                queue([item])
            }
            Button("Cancel", role: .cancel) { pendingReplace = nil }
        } message: {
            Text("Something is already playing there.")
        }
    }

    /// True only for the video that was actually pressed, so the dialog
    /// presents from that cell and nowhere else.
    private func choosing(_ item: LocalVideoAsset) -> Binding<Bool> {
        Binding(
            get: { pendingChoice?.asset.id == item.id },
            set: { if !$0, pendingChoice?.asset.id == item.id { pendingChoice = nil } }
        )
    }

    private func replacing(_ item: LocalVideoAsset) -> Binding<Bool> {
        Binding(
            get: { pendingReplace?.id == item.id },
            set: { if !$0, pendingReplace?.id == item.id { pendingReplace = nil } }
        )
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
        .padding(.top, 6)
        .padding(.bottom, 10)
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

            // Captioned and filled, unlike the glyphs around it: this is the
            // action the selection was made for, and a bare triangle did not
            // say whether it meant one video or all of them.
            Button { playSelection(picked) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                    Text(playLabel(picked)).font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(picked.isEmpty ? PanuraTheme.surfaceVariant : PanuraTheme.accent)
                )
                .foregroundStyle(picked.isEmpty ? PanuraTheme.onSurfaceVariant : Color.black)
            }
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

    /// The TV in use, if any — named, because "Play on VU TV" is a different
    /// promise from "Play on TV".
    private var tvName: String? {
        if panuraCast.isTVConnected, !panuraCast.connectedTVName.isEmpty {
            return panuraCast.connectedTVName
        }
        return chromecast.connectedDeviceName
    }

    private var tvConnected: Bool { panuraCast.isTVConnected || chromecast.isConnected }

    /// Tapping a video with a TV connected asks where it should play.
    ///
    /// Android does the same, and for the same reason: connecting a TV is not
    /// a promise that everything goes to it — half the time the phone is the
    /// screen you meant. Guessing either way is wrong often enough to be worth
    /// one tap.
    private func playOrAsk(_ asset: LocalVideoAsset, at index: Int) {
        guard tvConnected else { play(asset, at: index); return }
        pendingChoice = (asset, index)
    }

    /// From the context menu, where the intent is already "on the TV".
    /// Says what pressing it will do, which changes with the selection and
    /// with whether a TV is listening.
    private func playLabel(_ picked: [LocalVideoAsset]) -> String {
        if picked.count > 1 { return tvConnected ? "Play \(picked.count)" : "Play all" }
        return "Play"
    }

    /// One selection, two destinations. With a TV connected the question is
    /// worth asking, because a selection is as often something to line up for
    /// the television as it is something to watch here.
    private func playSelection(_ picked: [LocalVideoAsset]) {
        guard !picked.isEmpty else { return }
        if tvConnected {
            pendingBatch = picked
            return
        }
        guard let first = picked.first,
              let index = model.visible.firstIndex(where: { $0.id == first.id })
        else { return }
        play(first, at: index)
        selecting = false
        selection.removeAll()
    }

    private func castOrAsk(_ assets: [LocalVideoAsset]) {
        guard !assets.isEmpty else { return }
        guard tvConnected else {
            // Nothing to send it to yet: the cast picker is the next step, and
            // the videos can be chosen again once a TV answers.
            CastPicker.shared.open()
            return
        }
        // Only ask when there is something to lose. An idle TV just plays them.
        if panuraCast.isCasting || chromecast.isCasting {
            pendingBatch = assets
        } else {
            cast(assets)
        }
    }

    /// Exports the asset and hands the file to whichever TV is connected.
    ///
    /// Both paths serve it from this phone, so playback lasts exactly as long
    /// as the phone stays on the network — there is no way around that for a
    /// file only this device has.
    /// Hands a video to `CastFlow`, which owns everything from here to a picture
    /// on the TV — and owns the screen that says so. Reading the file is still
    /// this screen's job, because only it knows the photo library.
    /// Sends videos to the TV, replacing whatever is there.
    private func cast(_ assets: [LocalVideoAsset]) {
        CastFlow.shared.replace(with: assets.map(queueItem))
    }

    /// Adds videos to the end of the queue. Starts them only if the TV is idle,
    /// which is what makes this different from casting.
    private func queue(_ assets: [LocalVideoAsset]) {
        CastFlow.shared.enqueue(assets.map(queueItem))
        flash(assets.count == 1 ? "Added to the queue" : "\(assets.count) added to the queue")
    }

    private func queueItem(_ asset: LocalVideoAsset) -> CastQueueItem {
        CastQueueItem(
            id: asset.id,
            title: asset.displayTitle(showExtension: showExtension),
            payload: .photo(localIdentifier: asset.id),
            posterImage: asset.thumbnail
        )
    }

    private func flash(_ message: String) {
        toastTask?.cancel()
        withAnimation { toast = message }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    private func play(_ asset: LocalVideoAsset, at index: Int) {
        Task {
            if let url = await model.resolveURL(for: asset) {
                // Written here rather than in resolveURL, which also runs for
                // Share — and sharing a video is not playing it.
                LocalVideosModel.lastPlayedID = asset.id
                lastPlayedID = asset.id
                playIndex = index
PlaybackSession.shared.play(
                    MediaItem(title: asset.title, url: url, isLocal: true),
                    playlist: localPlaylist()
                )
            }
        }
    }
}

private struct VideoCell: View {
    let item: LocalVideoAsset
    let title: String
    var selected = false
    var selecting = false
    /// The one played most recently, marked with a stripe under the thumbnail —
    /// Android marks it with an accent edge for the same reason: in a library of
    /// near-identical thumbnails, "where was I" is the hardest question.
    var lastPlayed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(item: item)
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // How long it is, where a thumbnail always carries it.
                DurationBadge(text: item.durationLabel).padding(5)

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
            HStack(spacing: 5) {
                if lastPlayed {
                    Capsule()
                        .fill(PanuraTheme.accent)
                        .frame(width: 3, height: 12)
                }
                Text(title).font(.caption).lineLimit(1)
            }
        }
    }
}

/// The poster frame, bounded.
///
/// The image is an `overlay` on the fill rather than a sibling in a `ZStack`,
/// and that is the whole point. `scaledToFill` reports a *layout* size larger
/// than the box in one axis, so as a ZStack sibling it grew the stack itself —
/// and `.bottomTrailing` then placed the duration badge at the bottom-right of
/// the overflowing image, outside the rounded clip. Hence a badge that appeared
/// on some videos and not others: it survived only when the clip's aspect
/// happened to be close to the video's. An overlay takes the fill's size, so
/// the stack stays the size of the box and the badge lands where it is aimed.
private struct Thumbnail: View {
    let item: LocalVideoAsset

    var body: some View {
        Rectangle()
            .fill(PanuraTheme.surfaceVariant)
            .overlay {
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                }
            }
            .clipped()
    }
}

/// How long the video runs. White on a scrim rather than on the frame itself,
/// because a poster frame can be any colour and a bright one swallowed it.
private struct DurationBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The list shape: a wide thumbnail on the left, then the name and what is
/// known about the file. Android's `VideoListItem` — 80pt tall, 120pt of
/// thumbnail — because a list earns its place by having room for a long
/// filename and the details a grid caption cannot hold.
private struct VideoRow: View {
    let item: LocalVideoAsset
    let title: String
    /// Filled in once the library has been asked; nil until then, and the chip
    /// simply is not there rather than showing a placeholder that jumps.
    var size: String?
    var selected = false
    var selecting = false
    var lastPlayed = false

    /// The facts worth scanning a list by, in the order they answer questions:
    /// how long, when, how good, how big. Whatever the library has not answered
    /// yet is simply absent — no placeholder that shifts the line when it
    /// arrives.
    private var metaLine: String {
        var parts = [item.durationLabel]
        if let created = item.createdLabel { parts.append(created) }
        if let quality = item.qualityLabel { parts.append(quality) }
        if let size { parts.append(size) }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 10) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
            }

            ZStack(alignment: .bottomTrailing) {
                Thumbnail(item: item)
                DurationBadge(text: item.durationLabel).padding(4)
            }
            // Wider than Android's 120, and 16:9 rather than a guess — a list
            // row is mostly empty next to the name, and the honest thing to put
            // in that space is more of the video.
            .frame(width: 142, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                // One line, dot-separated, spanning the row rather than a
                // cluster of pills hugging the left edge with half the width
                // left over. Duration leads it: the badge sits on the frame,
                // but sorting a library by length means reading it in text.
                Text(metaLine)
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .padding(.leading, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(selected ? PanuraTheme.accentSoft : PanuraTheme.surfaceContainer)
        )
        // The accent edge marking "where was I" rides *on* the row rather than
        // sitting inside the stack. As a first child it pushed the thumbnail
        // across, so the one marked row was the one row out of alignment with
        // the rest of the list.
        .overlay(alignment: .leading) {
            if lastPlayed {
                Capsule()
                    .fill(PanuraTheme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 12)
                    .padding(.leading, 3)
            }
        }
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
