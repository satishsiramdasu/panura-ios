import SwiftUI

/// Home tab. Mirrors Android's `HomeTab`: address pill header, brand block with
/// version + action links, then Bookmarks · Continue Watching · Most Visited.
struct HomeView: View {
    /// Hands a raw address-bar string (URL or search terms) to the Browser tab.
    var onOpenBrowser: (String) -> Void
    /// Home is the hub for everything without a seat in the bottom bar, so the
    /// Options grid needs a way to send you there.
    var onOpenSection: (AppDestination) -> Void = { _ in }

    @ObservedObject private var store = BrowsingStore.shared
    @ObservedObject private var session = BrowserSession.shared

    @State private var showAddress = false
    @State private var showBookmarksSheet = false
    @State private var editingBookmark: SiteEntry?

    @State private var showReport = false
    @State private var showErase = false
    /// URL of the resume card being checked, so it can show it is working.
    @State private var checkingResume: String?
    /// The card a Remove was asked for — held until it is confirmed.
    @State private var pendingRemove: ResumeEntry?

    /// Said once, when a card turns out to be dead.
    @State private var resumeToast: String?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    brandBlock
                    bookmarksSection
                    if !store.continueWatching.isEmpty { continueWatchingSection }
                    // Before the destinations, where the cast card used to
                    // sit after them. Casting is something you reach for once
                    // you have already chosen what to watch, which made it the
                    // last card on a screen people open in order to start
                    // watching. Picking a video *is* starting, so it goes with
                    // Bookmarks and Continue Watching - the three ways to be
                    // playing something within one tap - and Explore stays
                    // below as the list of places to go instead.
                    PickVideoCard().padding(.horizontal, 16)
                    quickAccessSection
                    housekeepingRow
                }
                .padding(.vertical, 20)
            }
            .background(PanuraTheme.background)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .navigationBarHidden(true)
            .overlay(alignment: .bottom) {
                if let resumeToast {
                    Text(resumeToast)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(PanuraTheme.surfaceContainerHigh, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
        }
        // Sweeps the saved links each time Home comes up. A card is a promise
        // that tapping it plays something, and browser stream URLs expire in
        // hours — Android does the same sweep from its Home for the same reason.
        .task { await store.pruneDeadResumes() }
        .fullScreenCover(isPresented: $showAddress) {
            AddressScreen(
                onNavigate: { text in
                    withoutSheetAnimation { showAddress = false }
                    onOpenBrowser(text)
                },
                onDismiss: { withoutSheetAnimation { showAddress = false } }
            )
        }
        .sheet(isPresented: $showBookmarksSheet) { bookmarksSheet }
        .sheet(isPresented: $showErase) { EraseAndExitSheet() }
        .sheet(item: $editingBookmark) { BookmarkEditor(entry: $0) }
        .sheet(isPresented: $showReport) { ReportIssueSheet(source: "home") }
        .confirmationDialog(
            "Remove from Continue Watching?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let entry = pendingRemove { store.removeWatching(url: entry.url) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text(pendingRemove.map { "\"\($0.title)\" will stop showing here." } ?? "")
        }
    }

    // MARK: quick access

    /// The four places worth going, as cards.
    ///
    /// Home is now where the destinations are reached from as well as the
    /// drawer - the bottom bar that used to carry Browser and Videos is gone -
    /// so these four are the whole of the app's navigation on this screen and
    /// have to be found at a glance rather than read.
    ///
    /// Headed "Explore", not "Quick access". Quick access is what the Bookmarks
    /// row directly above it is: sites the user put there to reach in one tap.
    /// These are the app's own places, and every one of them is where you go
    /// when a bookmark was not what you wanted.
    ///
    /// Which is why Settings is no longer among them. It is not a place you go
    /// to watch something; it is something you adjust, and it sits with the
    /// other two of those at the bottom of the screen.
    ///
    /// Watch Later has the fourth seat. Bookmarks is the site you return to and
    /// Continue Watching is the thing you are part-way through; neither answers
    /// "the one I found yesterday and meant to get to", which is the commonest
    /// thing to lose in a browser.
    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Explore")
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                sectionCard(.web, title: "Web\nBrowser")
                sectionCard(.videos, title: "Phone\nVideos")
                sectionCard(.stream, title: "Network\nStream")
                sectionCard(.watchLater, title: "Watch\nLater")
            }
            .padding(.horizontal, 16)
        }
    }

    private func sectionCard(
        _ destination: AppDestination,
        title: String
    ) -> some View {
        card(
            title: title,
            icon: destination.icon(selected: true),
            tint: destination.tint
        ) { onOpenSection(destination) }
    }

    /// Name at the top left, mark at the bottom right, and wider than it is
    /// tall.
    ///
    /// The caption is gone with the height. Stacked - glyph, gap, name, sentence
    /// - the card had to be 148 tall, and four of those filled a screen on their
    /// own and pushed everything Home is actually for below the fold. Set the
    /// two diagonally instead and the same card is 92: the name reads first at
    /// the corner the eye starts from, and the mark fills the space left over
    /// rather than costing a row of its own.
    private func card(
        title: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                // Large, and pushed into the corner far enough to be cropped by
                // it. A mark sized to sit politely inside the box reads as an
                // icon labelling the card; one that runs off the edge reads as
                // artwork the card is made of, which is what gives these their
                // weight at this size.
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(tint)
                    .offset(x: 10, y: 6)
            }
            .padding(.leading, 14)
            .padding(.vertical, 12)
            .frame(height: 84)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Each card in its own colour, faintly. Four grey boxes had to be
            // read one at a time; four colours are told apart before they are
            // read, which is the whole job of a grid you use every day.
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The two that are actions rather than places, kept small because that is
    /// what they are.
    private var housekeepingRow: some View {
        HStack(spacing: 10) {
            // Settings is not somewhere you go, it is something you adjust, and
            // it was taking a quarter of the navigation grid to say so. Down
            // here with the other two things you do to the app rather than with
            // it, and still on the drawer for anyone who looks there first.
            optionTile("Settings", systemImage: "gearshape") { onOpenSection(.settings) }
            optionTile("Report Issue", systemImage: "ladybug") { showReport = true }
            // A menu rather than a dialog. A confirmation dialog on iOS comes
            // up from the bottom of the screen, a long way from the tile that
            // raised it and carrying no trace of which one that was; a menu
            // opens on the button, so the question stays attached to the thing
            // being asked about.
            optionMenu("Clear History", systemImage: "trash") {
                Section("Most Visited and recent pages go. Bookmarks and Continue Watching stay.") {
                    Button(role: .destructive) {
                        store.clearHistory()
                    } label: { Label("Clear History", systemImage: "trash") }
                }
                // Its own section: this one is not a bigger version of the
                // button above it. That clears two lists and leaves you where
                // you were; this can take everything and closes the app.
                Section {
                    Button(role: .destructive) {
                        showErase = true
                    } label: { Label("Erase Data & Exit", systemImage: "xmark.octagon") }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// The same tile, opening a menu instead of running an action.
    private func optionMenu<Items: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder items: () -> Items
    ) -> some View {
        Menu {
            items()
        } label: {
            optionTileLabel(title, systemImage: systemImage)
        }
    }

    /// The same header, whose action button opens a menu.
    private func sectionHeaderMenu<Items: View>(
        _ title: String,
        actionLabel: String,
        actionIcon: String,
        @ViewBuilder items: () -> Items
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                items()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: actionIcon).font(.system(size: 11))
                    Text(actionLabel).font(.caption)
                }
                .foregroundStyle(PanuraTheme.accent)
            }
        }
        .padding(.horizontal, 16)
    }

    private func optionTile(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            optionTileLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    /// The drawing, shared by the button form and the menu form.
    private func optionTileLabel(_ title: String, systemImage: String) -> some View {
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
        .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    // MARK: header — address pill, same shape as the browser's top bar

    private var header: some View {
        PanuraHeader(showsGlyph: false) {
            AddressPill(
                title: "",
                url: "",
                placeholder: session.privateMode
                    ? "Search privately"
                    : "Search Google or enter website",
                // Tinted for private browsing, as the browser's bar is — the
                // two read as one bar and have to agree.
                background: session.privateMode
                    ? PanuraTheme.incognito.opacity(0.22)
                    : PanuraTheme.surfaceVariant,
                onTap: { withoutSheetAnimation { showAddress = true } },
                leading: {
                    // The mark, in the same cell the browser's pill gives it,
                    // so the two bars stay the one bar they are meant to read
                    // as. It replaces a magnifying glass that was saying what
                    // the placeholder beside it already says.
                    //
                    // Tapping it opens the address screen like the rest of the
                    // pill: there is nowhere for a Home glyph to go, and a mark
                    // that does nothing inside a control that does something is
                    // a dead spot in the middle of the target.
                    PanuraGlyph(
                        onTap: { withoutSheetAnimation { showAddress = true } },
                        label: "Search or enter website",
                        tint: session.privateMode ? PanuraTheme.incognito : nil
                    )
                },
                trailing: {
                    // Same cell Android puts it in: last inside Home's pill. It
                    // is browser state, but this is where a session is started,
                    // so this is where it has to be switchable — the browser's
                    // own copy of the switch is in its options panel.
                    Button {
                        session.setPrivateMode(!session.privateMode)
                    } label: {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 15))
                            .foregroundStyle(
                                session.privateMode
                                    ? PanuraTheme.incognito
                                    : PanuraTheme.onSurfaceVariant
                            )
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        session.privateMode ? "Turn off private browsing" : "Private browsing"
                    )
                }
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
                Text("VIDEO BROWSER")
                    .font(.caption2.weight(.medium))
                    .tracking(2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                ShareLink(
                    item: URL(string: "https://panura.app")!,
                    // No "download". There is no download feature on iOS — the
                    // code was deleted rather than gated, because saving media
                    // from third-party sites is what Review 5.2.3 names — and
                    // the FAQ two screens away says so outright. This was the
                    // one string in the app promising the opposite, in the one
                    // place users forward to other people.
                    message: Text("Panura Player — browse, play & cast web videos.")
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

    // MARK: bookmarks

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Bookmarks", showAll: !store.bookmarks.isEmpty) {
                showBookmarksSheet = true
            }
            if store.bookmarks.isEmpty {
                emptyHint("Add any website as a bookmark to show here.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.bookmarks.prefix(10)) { item in
                            BookmarkTile(entry: item)
                                .onTapGesture { onOpenBrowser(item.url) }
                                .contextMenu {
                                    Button { editingBookmark = item } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        store.removeBookmark(url: item.url)
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
            sectionHeaderMenu("Continue Watching", actionLabel: "Clear all", actionIcon: "trash") {
                Section("The videos stay. Only the resume points go.") {
                    Button(role: .destructive) {
                        store.clearWatching()
                    } label: {
                        Label("Clear \(store.continueWatching.count) items", systemImage: "trash")
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.continueWatching) { entry in
                        ContinueWatchingCard(entry: entry)
                            // Checked before it opens, not after: a saved stream
                            // URL is a token with an expiry, and the failure it
                            // produces inside the player is a black screen with
                            // no explanation.
                            .overlay {
                                if checkingResume == entry.url {
                                    ZStack {
                                        Color.black.opacity(0.45)
                                        ProgressView().controlSize(.small)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                            .onTapGesture { openResume(entry) }
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingRemove = entry
                                } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Verifies before playing, and drops the entry if the link is gone. The
    /// toast matters: a card vanishing under your finger with no word is a bug,
    /// the same thing with a line of text is an explanation.
    private func openResume(_ entry: ResumeEntry) {
        guard checkingResume == nil else { return }
        checkingResume = entry.url
        Task {
            let alive = await BrowsingStore.isAlive(entry)
            checkingResume = nil
            if alive {
                PlaybackSession.shared.play(entry.mediaItem)
            } else {
                store.removeWatching(url: entry.url)
                resumeToast = "That link has expired — open the page again."
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                resumeToast = nil
            }
        }
    }

    // MARK: sheets

    private var bookmarksSheet: some View {
        NavigationStack {
            List {
                ForEach(store.bookmarks) { item in
                    Button {
                        showBookmarksSheet = false
                        onOpenBrowser(item.url)
                    } label: { SiteRow(entry: item) }
                        .buttonStyle(.plain)
                }
                .onDelete { store.removeBookmark(url: store.bookmarks[$0.first ?? 0].url) }
                .onMove { store.moveBookmarks(from: $0, to: $1) }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showBookmarksSheet = false }
                }
            }
        }
    }

    // MARK: bits

    /// Title, an optional "Show all", and an optional trailing action —
    /// Android's `SectionHeader`, which carries the same two slots.
    private func sectionHeader(
        _ title: String,
        showAll: Bool = false,
        actionLabel: String? = nil,
        actionIcon: String? = nil,
        action: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 10) {
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
                .buttonStyle(.plain)
            }
            if let actionLabel {
                Button(action: action) {
                    HStack(spacing: 3) {
                        if let actionIcon {
                            Image(systemName: actionIcon).font(.system(size: 11))
                        }
                        Text(actionLabel).font(.caption)
                    }
                    .foregroundStyle(PanuraTheme.accent)
                }
                .buttonStyle(.plain)
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

private struct BookmarkTile: View {
    let entry: SiteEntry

    var body: some View {
        VStack(spacing: 4) {
            Favicon(entry: entry, size: 30)
                .padding(13)
                .background(PanuraTheme.surfaceVariant, in: Circle())
            Text(entry.title)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 72)
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
                .fill(PanuraTheme.surfaceVariant)

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
                    .background(PanuraTheme.background.opacity(0.75))
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

/// Title/URL editor for a pinned bookmark.
private struct BookmarkEditor: View {
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
            .navigationTitle("Edit Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        store.updateBookmark(
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
