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

    @State private var showClearData = false
    @State private var showLibrary = false
    /// Which of the Library's three tabs the next opening lands on.
    @State private var libraryTab: LibrarySheet.Tab = .watching
    /// URL of the resume card being checked, so it can show it is working.
    @State private var checkingResume: String?
    /// The card a Remove was asked for — held until it is confirmed.
    @State private var pendingRemove: ResumeEntry?

    /// Said once, when a card turns out to be dead.
    @State private var resumeToast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    bookmarksSection
                    if !store.continueWatching.isEmpty { continueWatchingSection }
                    // Before the destinations, where the cast card used to
                    // sit after them. Casting is something you reach for once
                    // you have already chosen what to watch, which made it the
                    // last card on a screen people open in order to start
                    // watching. Picking a video *is* starting, so it goes with
                    // Bookmarks and Continue Watching - the three ways to be
                    // playing something within one tap.
                    // Above Pick a video, because it is the more specific
                    // offer: one named page somebody was actually reading
                    // beats a picker over the whole library.
                    if let last = store.lastVisited { continueBrowsingCard(last) }
                    // The ways to start something this minute, in one shape,
                    // one under the other. They used to be a card and a grid
                    // of tiles headed "Explore", which put the same kind of
                    // act into two different kinds of furniture — and the
                    // heading promised places to go while holding two
                    // leftovers.
                    VStack(spacing: 10) {
                        PickVideoCard()
                        networkStreamCard
                    }
                    .padding(.horizontal, 16)
                    housekeepingRow
                    // Last, under the cards. They were beside the name at the
                    // very top, which gave the two least-pressed controls on
                    // the screen the best position on it - and the name has
                    // gone up to the app header, so there is nothing left to
                    // sit beside.
                    communityRow
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
        // A row in there hands its video to the session and closes rather
        // than presenting a player underneath this sheet; this is where it
        // starts. See `PlaybackSession.playWhenDismissed`.
        .sheet(
            isPresented: $showLibrary,
            onDismiss: { PlaybackSession.shared.flushPending() }
        ) {
            LibrarySheet(tab: libraryTab, onOpenBrowser: onOpenBrowser)
        }
        // An overlay, not a sheet: it has to arrive centred, where the eye
        // already is, rather than sliding up from the far end of the screen.
        .overlay {
            if showClearData {
                ClearDataDialog(isPresented: $showClearData) { flashResume($0) }
            }
        }
        .sheet(item: $editingBookmark) { BookmarkEditor(entry: $0) }
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

    // MARK: starting something

    /// Paste an address and play it. Same shape as Pick a video, because it
    /// is the same kind of thing: not a place, an act.
    private var networkStreamCard: some View {
        actionCard(
            icon: "dot.radiowaves.left.and.right",
            title: "Network Stream",
            detail: "Play a link you already have",
            action: "Open"
        ) { onOpenSection(.stream) }
    }

    /// `PickVideoCard`'s shape, for the cards that sit with it. Kept in step
    /// with it by hand rather than shared: that one carries a picker, a
    /// loading state and a Photos round trip, and pulling a common card out of
    /// it would be a worse abstraction than two views that look alike.
    private func actionCard(
        icon: String,
        title: String,
        detail: String,
        action: String,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(PanuraTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(action)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PanuraTheme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(PanuraTheme.accent, in: Capsule())
            }
            .padding(12)
            .background(PanuraTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The small things: two lists you go looking for, and one way to tidy
    /// up after yourself.
    ///
    /// Watch Later and Watch History are here rather than in the header menu,
    /// which is where they briefly were. A menu is the right place for
    /// something you need from every screen; these are things you go looking
    /// for, and looking for something on Home is what Home is. It also means
    /// Watch Later no longer depends on Continue Watching having a row — the
    /// header shortcut vanished exactly when there was nothing to continue,
    /// which is when somebody wants what they saved.
    ///
    /// Settings and Report Issue are not here. Both are one tap away in the
    /// header menu, from every tab — a tile that repeats a menu row teaches
    /// people the menu is not worth opening, and Home has better things to
    /// spend a third of a row on.
    ///
    /// Clear Data stays, because its only other home is two levels down in
    /// Settings → Web Browser, and it is the one thing on that path people
    /// actually come looking for.
    ///
    /// "Clear Data", not "Clear History": history is one of seven things it
    /// can take. One tile, one dialog, every choice in it — rather than a menu
    /// whose items each did a different amount of damage with no way to see
    /// what any of them would take.
    private var housekeepingRow: some View {
        HStack(spacing: 10) {
            optionTile("Watch Later", systemImage: "clock") { openLibrary(.later) }
            optionTile("Watch History", systemImage: "checkmark.circle") {
                openLibrary(.history)
            }
            optionTile("Clear Data", systemImage: "trash") {
                withAnimation(.easeOut(duration: 0.15)) { showClearData = true }
            }
        }
        .padding(.horizontal, 16)
    }

    private func openLibrary(_ tab: LibrarySheet.Tab) {
        libraryTab = tab
        showLibrary = true
    }

    /// One of the squares at the foot of the screen.
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

    /// The drawing. Lifted out of `optionTile` because a menu form used to
    /// share it; kept separate because the next one will.
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

    // MARK: header — a search bar, and the private switch beside it

    /// Home asks one question — what do you want to watch — so its bar is a
    /// search field and nothing else, with the one piece of state that changes
    /// the answer standing next to it rather than hidden inside it.
    ///
    /// **No Panura mark in the field.** It sat in the pill's leading cell so
    /// this bar and the browser's would read as one bar, which they do not:
    /// the browser's pill shows a page and belongs to that page, while this
    /// one is empty and is asking. A magnifying glass says what the control
    /// does; a logo says which app you are in, and four tabs below already
    /// said that.
    private var header: some View {
        PanuraHeader(showsGlyph: false) {
            HStack(spacing: 8) {
                searchPill
                privateTile
            }
        }
    }

    private var searchPill: some View {
        Button { withoutSheetAnimation { showAddress = true } } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                Text(
                    session.privateMode
                        ? "Search privately"
                        : "Search Google or enter website"
                )
                .font(.subheadline)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.barHeight)
            .frame(maxWidth: .infinity)
            .background(barFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search or enter website")
    }

    private var privateTile: some View {
        PrivateSwitchTile(
            on: session.privateMode,
            hasPage: session.hasPage,
            fill: barFill,
            height: Self.barHeight
        ) { keepPage in
            session.setPrivateMode(!session.privateMode, keepingPage: keepPage)
        }
    }

    /// Both halves of the bar are this tall and this colour, which is what
    /// makes them read as one control split in two rather than as a field with
    /// a button parked next to it.
    private static let barHeight: CGFloat = 46

    private var barFill: Color {
        // Tinted for private browsing, as the browser's own bar is — the two
        // have to agree about what a session looks like.
        session.privateMode
            ? PanuraTheme.incognito.opacity(0.22)
            : PanuraTheme.surfaceVariant
    }

    // MARK: community links

    /// Share and Telegram, at the foot of the screen.
    ///
    /// They used to be a column beside the app's name at the very top, which
    /// gave the two least-pressed controls on Home the most valuable position
    /// on it. The name has moved to the app header, and these follow the cards
    /// instead of preceding them - which is also where a person who has
    /// finished looking at their videos actually is.
    private var communityRow: some View {
        HStack(spacing: 10) {
            ShareLink(
                item: URL(string: "https://panura.app")!,
                // No "download". There is no download feature on iOS - the
                // code was deleted rather than gated, because saving media
                // from third-party sites is what Review 5.2.3 names - and
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private func linkLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PanuraTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(PanuraTheme.surfaceVariant, in: Capsule())
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

    // MARK: carry on browsing

    /// The page the browser was last on, offered rather than reopened.
    ///
    /// The app does not restore the browser tab and does not reload the site —
    /// an app that silently fetches a page on launch spends somebody's data on
    /// a guess, and lands them on a video site they were finished with. This is
    /// the same fact as a tap instead: one line, the page's own name, the host
    /// underneath, and nothing happens until it is pressed.
    ///
    /// It is absent after private browsing and after Clear History, because it
    /// reads from history and both of those leave none.
    private func continueBrowsingCard(_ entry: SiteEntry) -> some View {
        Button { onOpenBrowser(entry.url) } label: {
            HStack(spacing: 12) {
                // The site's own mark, which is how people recognise a site
                // — the card says a name and a host, and neither is read as
                // fast as the icon. The back-arrow glyph stays as the fallback
                // for a site with no icon, or no network to fetch one.
                RoundedRectangle(cornerRadius: 12)
                    .fill(PanuraTheme.accentSoft)
                    .frame(width: 42, height: 42)
                    .overlay {
                        RemoteImage(url: entry.faviconURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                                    .frame(width: 22, height: 22)
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    )
                            } else {
                                Image(systemName: "arrow.uturn.left.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(PanuraTheme.accent)
                            }
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue where you left off")
                        .font(.caption)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(1)
                    // The page's own name first and its host under it. A title
                    // is what somebody remembers reading; a host is how they
                    // check it is the right one.
                    Text(entry.title.isEmpty ? entry.url : entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let host = URL(string: entry.url)?.host {
                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            .padding(12)
            .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityLabel("Continue browsing \(entry.title.isEmpty ? entry.url : entry.title)")
    }

    // MARK: continue watching

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // "Show all", the same affordance Bookmarks uses, because it is
            // the same act: this row is the first few of a list, and that is
            // the rest of it. It said "Manage" with a slider glyph while the
            // sheet it opened was a resume manager and nothing else — the
            // sheet is the Library now, and two words for one gesture on one
            // screen is how a person learns that two things are different
            // when they are not.
            //
            // Removing still lives in there, which is what "Manage" was for.
            // It was never the reason anybody pressed it.
            sectionHeader("Continue Watching", showAll: true) {
                openLibrary(.watching)
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
                            // A dead card asks instead of opening. Tapping it
                            // used to start a check that ended in the card
                            // vanishing; now the card says what it is and
                            // offers the two things worth doing with it.
                            .overlay {
                                if entry.isExpired { expiredMenu(entry) }
                            }
                            .onTapGesture { if !entry.isExpired { openResume(entry) } }
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

    /// The whole card, as a menu, for an entry whose link has died.
    ///
    /// An overlay rather than a second card: the card underneath already draws
    /// itself faded, and this only has to catch the tap and offer the choice.
    private func expiredMenu(_ entry: ResumeEntry) -> some View {
        Menu {
            Section("This link has expired. The page it came from may still work.") {
                if let page = entry.sourcePage {
                    Button {
                        onOpenBrowser(page.absoluteString)
                    } label: { Label("Visit website", systemImage: "safari") }
                }
                Button(role: .destructive) {
                    store.removeWatching(url: entry.url)
                } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Color.clear.contentShape(Rectangle())
        }
        .menuOrder(.fixed)
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
                // Marked, not deleted. The card stays, greyed, offering the
                // page it came from - which is nearly always still there.
                store.markExpired(url: entry.url)
                flashResume("That link has expired.")
            }
        }
    }

    /// The one toast this screen has. Cleared only if nothing else has claimed
    /// it since, so a second message is not wiped by the first one's timer.
    private func flashResume(_ message: String) {
        resumeToast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if resumeToast == message { resumeToast = nil }
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

    /// The grabbed frame, decoded once when the card appears and off the main
    /// thread. A computed property would re-read the file on every layout pass,
    /// and the row is a horizontal scroller. The file lives in Caches and may
    /// be gone, so a failed load is ordinary.
    @State private var thumbnail: UIImage?

    /// The site's poster, if there is one.
    ///
    /// Tried first, and the frame is the fallback rather than the source. A
    /// frame only exists once something has played long enough to grab one, and
    /// it sits in Caches where the system evicts it whenever it likes - which
    /// is why most of these cards were showing a glyph.
    private var posterURL: URL? { entry.poster.flatMap(URL.init(string:)) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(PanuraTheme.surfaceVariant)

            if let posterURL {
                RemoteImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    // A poster that will not load is no better than no poster,
                    // so it steps aside for the frame rather than leaving a
                    // hole where a picture was promised.
                    case .failure: grabbedFrame
                    default: Color.clear
                    }
                }
                .frame(width: 140, height: 90)
                .clipped()
            } else {
                grabbedFrame
            }

            if !entry.isExpired {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let left = entry.timeLeftLabel {
                Text(left)
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
        // Faded, and saying so. A dead link is still worth keeping - the page
        // behind it usually works - but it should not look like something
        // that will play when pressed.
        .opacity(entry.isExpired ? 0.45 : 1)
        .overlay(alignment: .center) {
            if entry.isExpired {
                Text("Link expired")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule())
            }
        }
        .task(id: entry.thumbnailPath) {
            guard let path = entry.thumbnailPath else { thumbnail = nil; return }
            thumbnail = await Task.detached { UIImage(contentsOfFile: path) }.value
        }
    }

    @ViewBuilder
    private var grabbedFrame: some View {
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
