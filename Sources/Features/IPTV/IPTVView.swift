import SwiftUI

/// What is inside one playlist: live channels, films and series.
///
/// Panura ships no playlists and no channels. It opens the address its owner
/// enters, exactly as the browser opens the address its owner types — which is
/// both the honest design and the one that does not put this app in the
/// business of distributing someone else's broadcast.
///
/// The list of playlists is not here. It is in `ServersView`, alongside the
/// NAS entries, because adding one is the same act either way — an address, a
/// sign-in, and a list that comes back. This screen is only ever shown for a
/// playlist that is already open.
struct IPTVView: View {
    @ObservedObject private var store = IPTVStore.shared
    @Environment(\.screenChrome) private var chrome
    @Environment(\.horizontalSizeClass) private var width

    /// Grid or rows, remembered. Grid by default: a channel list is a wall of
    /// names and a wall of logos is the one a person reads faster — the logo is
    /// what a provider actually puts work into, and it is how most people know
    /// the channel. The switch is there because a thousand-channel package is
    /// quicker to scan as text, and that is a real preference rather than a
    /// wrong one.
    @AppStorage("iptv_layout") private var layout: IPTVLayout = .grid
    @ObservedObject private var shell = ShellChrome.shared
    /// Watched marks and resume points, for the strip under a film's poster.
    @ObservedObject private var watching = BrowsingStore.shared

    @State private var query = ""
    @State private var group: String?
    @State private var openSeries: XtreamSeries?
    /// Whether the search field has the whole row to itself.
    @State private var searching = false
    @State private var showGroups = false
    @FocusState private var searchFocused: Bool

    private static let reveal = Animation.easeInOut(duration: 0.2)

    /// Above this many groups, the dropdown becomes a sheet that can be
    /// searched. A native menu has no search and no index, so a panel's three
    /// hundred categories in one are the chip strip's problem rotated ninety
    /// degrees.
    private static let menuLimit = 20

    var body: some View {
        channelList
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(PanuraTheme.background)
            .safeAreaInset(edge: .top, spacing: 0) { bar }
            .sheet(item: $openSeries) { show in
                IPTVSeriesSheet(show: show)
            }
    }

    // MARK: bar

    private var bar: some View {
        HStack(spacing: 10) {
            glyph("chevron.left", label: "All servers") {
                store.close()
                query = ""
                group = nil
                searching = false
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(store.open?.displayName ?? "Playlist")
                    .font(.headline)
                    .lineLimit(1)
                if !store.channels.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Outside the loading branch: the layout is a preference about
            // what is already on screen, and taking it away while a refetch
            // runs would be taking away the one control that still works.
            glyph(
                layout.next.icon,
                label: layout == .grid ? "Show a list" : "Show a grid"
            ) {
                layout = layout.next
            }
            if store.isLoading {
                ProgressView().controlSize(.small).frame(width: 34, height: 34)
            } else if let open = store.open {
                glyph("arrow.clockwise", label: "Reload channels") {
                    Task { await store.load(open, force: true) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(chrome)
    }

    /// How many channels, how old they are, and when the subscription runs
    /// out.
    ///
    /// The age matters here in a way it does not elsewhere: a playlist is
    /// somebody else's list and it changes without warning, so "loaded an hour
    /// ago" is the answer to "why is that channel missing". And the expiry is
    /// the question every one of these users eventually has, asked of an app
    /// that has it to hand and has no reason to keep it.
    private var subtitle: String {
        var parts = ["\(store.channels.count) channels"]
        if let at = store.fetchedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append(formatter.localizedString(for: at, relativeTo: Date()))
        }
        if let expires = store.account?.expires {
            parts.append("expires " + expires.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private func glyph(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: channels

    private var visible: [M3UChannel] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return store.listed.filter { channel in
            if let group, channel.group != group { return false }
            guard !text.isEmpty else { return true }
            return channel.name.range(of: text, options: .caseInsensitive) != nil
        }
    }

    @ViewBuilder
    private var channelList: some View {
        VStack(spacing: 0) {
            if store.hasCatalogue { sectionStrip }
            filterRow

            if store.section == .series {
                seriesList
            } else if store.listed.isEmpty {
                if store.isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading the channel list…")
                            .font(.footnote)
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(store.failure ?? "No channels in that playlist.")
                        .font(.footnote)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 32)
                }
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        Color.clear.frame(height: 0).id(Self.topAnchor)
                        LazyVGrid(columns: columns, spacing: layout == .grid ? 14 : 0) {
                            ForEach(visible) { channel in
                                channelCell(channel)
                            }
                        }
                        .padding(.horizontal, layout == .grid ? 12 : 16)
                        .padding(.vertical, layout == .grid ? 12 : 0)
                        // Scrolling a channel list down takes the header and
                        // the tab strip with it, and the top brings them back —
                        // the same deal as the browser and the library, which
                        // is why this is a `ScrollView` and a grid of one
                        // column rather than a `List`: the probe has to find a
                        // scroll view by walking up from inside the content.
                        .scrollAwayChrome(.ftp)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if shell.farFromTop { toTopButton(scroller) }
                    }
                }
            }
        }
    }

    /// Three across on a phone, six on an iPad; one in a list.
    ///
    /// Fixed counts rather than `.adaptive`, which fits whatever it can and so
    /// puts five tiles on a Pro Max and three on a mini — a grid that changes
    /// shape with the handset is a grid nobody can learn.
    private var perRow: Int { width == .regular ? 6 : 3 }

    private var columns: [GridItem] {
        layout == .list
            ? [GridItem(.flexible(), spacing: 0)]
            : Array(repeating: GridItem(.flexible(), spacing: 10), count: perRow)
    }

    /// Where the top is, for `toTopButton`. Not the first tile — the grid
    /// starts below its own padding, so aiming at a tile stops short of the
    /// actual top and the chrome never hears that it has arrived.
    private static let topAnchor = "iptv.top"

    /// Back to the top, and with it the header and the tabs.
    ///
    /// The chrome returns at the top and nowhere else, which is only fair if
    /// the top is somewhere you can get to. A subscription runs to hundreds of
    /// channels and a film catalogue to thousands, so this screen needs it more
    /// than the library did. Shown only two screens down — nearer than that the
    /// top is one swipe away and the button is the more annoying of the two.
    private func toTopButton(_ scroller: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.3)) {
                scroller.scrollTo(Self.topAnchor, anchor: .top)
            }
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PanuraTheme.onSurface)
                .frame(width: 42, height: 42)
                .background(Circle().fill(PanuraTheme.surfaceContainerHighest))
                .overlay(Circle().strokeBorder(PanuraTheme.outlineVariant, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityLabel("Back to top")
    }

    /// One cell of whichever layout is on.
    ///
    /// The cell owns its button rather than being wrapped in one, so that in
    /// list form the separator can sit *outside* it: a hairline between two
    /// rows belongs to neither, and inside the button it would light up as
    /// part of whichever row was pressed.
    @ViewBuilder
    private func channelCell(_ channel: M3UChannel) -> some View {
        if layout == .grid {
            Button { play(channel) } label: { channelTile(channel) }
                .buttonStyle(.plain)
        } else {
            VStack(spacing: 0) {
                Button { play(channel) } label: { channelRow(channel) }
                    .buttonStyle(.plain)
                Divider().overlay(PanuraTheme.outlineVariant)
            }
        }
    }

    /// A tile: the picture, and the name under it.
    ///
    /// **Two shapes, because there are two kinds of picture.** A channel logo
    /// is square-ish, drawn on transparency, and the same in every provider's
    /// list — cropped to a 16:9 thumbnail it loses its top and bottom, so it
    /// gets a square and is fitted inside it rather than filling it. A film is
    /// a poster: 2:3, filled and cropped, because a poster shown at any other
    /// ratio reads as a mistake.
    private func channelTile(_ channel: M3UChannel) -> some View {
        let poster = store.section == .movies
        // Films only. A live channel is not something you are part-way
        // through, and a strip under one would be measuring a thing that has
        // no end.
        let state = poster ? watching.watchState(channel.url.absoluteString) : WatchState.unseen
        return VStack(alignment: .leading, spacing: 6) {
            artwork(
                channel.logo, poster: poster, fallback: poster ? "film" : "tv", state: state
            )
            Text(channel.name)
                .font(.caption)
                // Reserved rather than merely limited: without it a one-line
                // name and a two-line name make two different row heights, and
                // the grid develops a ragged baseline down the screen.
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The reserved second line is empty space for most tiles, and empty
        // space in a label is not a target unless it is told to be.
        .contentShape(Rectangle())
    }

    /// The picture part of a tile, at whichever of the two shapes.
    ///
    /// An `overlay` on the fill, never a `ZStack` sibling: `scaledToFill`
    /// reports a layout size larger than its box in one axis, so as a sibling
    /// it grows the stack and the tile stops being the shape it was told to be.
    /// Learned here once already — see `Thumbnail` in the Videos tab.
    private func artwork(
        _ url: URL?, poster: Bool, fallback: String, state: WatchState = .unseen
    ) -> some View {
        Rectangle()
            .fill(PanuraTheme.surfaceContainerHigh)
            .aspectRatio(poster ? 2.0 / 3.0 : 1, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        if poster {
                            image.resizable().scaledToFill()
                        } else {
                            image.resizable().scaledToFit().padding(10)
                        }
                    } else {
                        Image(systemName: fallback)
                            .font(.system(size: 20))
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    }
                }
            }
            // Inside the clip, so the strip follows the corner it sits in.
            .overlay(alignment: .bottom) { WatchStrip(state: state) }
            .overlay(alignment: .topTrailing) {
                if state == .finished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, PanuraTheme.accent)
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Live, Movies, Series. Only for an account that has the last two — an
    /// M3U address is a channel list and nothing else, and a switcher with one
    /// working position is a switcher that teaches people not to press it.
    private var sectionStrip: some View {
        Picker("Section", selection: Binding(
            get: { store.section },
            set: { wanted in
                group = nil
                query = ""
                searching = false
                searchFocused = false
                Task { await store.loadSection(wanted) }
            }
        )) {
            ForEach(IPTVStore.Section.allCases) { section in
                Text(section.label).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(chrome)
    }

    private var visibleSeries: [XtreamSeries] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return store.series.filter { show in
            if let group, show.group != group { return false }
            guard !text.isEmpty else { return true }
            return show.name.range(of: text, options: .caseInsensitive) != nil
        }
    }

    @ViewBuilder
    private var seriesList: some View {
        if store.series.isEmpty {
            if store.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading the series list…")
                        .font(.footnote)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(store.failure ?? "No series in this playlist.")
                    .font(.footnote)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 32)
            }
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    LazyVGrid(columns: columns, spacing: layout == .grid ? 14 : 0) {
                        ForEach(visibleSeries) { show in
                            seriesCell(show)
                        }
                    }
                    .padding(.horizontal, layout == .grid ? 12 : 16)
                    .padding(.vertical, layout == .grid ? 12 : 0)
                    .scrollAwayChrome(.ftp)
                }
                .overlay(alignment: .bottomTrailing) {
                    if shell.farFromTop { toTopButton(scroller) }
                }
            }
        }
    }

    @ViewBuilder
    private func seriesCell(_ show: XtreamSeries) -> some View {
        if layout == .grid {
            Button { openSeries = show } label: {
                VStack(alignment: .leading, spacing: 6) {
                    // Always a poster, in both sections that have one: a
                    // series is sold by its cover exactly as a film is. No
                    // strip on it, though — "40% of a series" is not a thing
                    // anybody means, and the episode list says it properly.
                    artwork(show.cover, poster: true, fallback: "rectangle.stack")
                    Text(show.name)
                        .font(.caption)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 0) {
                Button { openSeries = show } label: { seriesRow(show) }
                    .buttonStyle(.plain)
                Divider().overlay(PanuraTheme.outlineVariant)
            }
        }
    }

    private func seriesRow(_ show: XtreamSeries) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(PanuraTheme.surfaceContainerHigh)
                .frame(width: 46, height: 69)
                .overlay {
                    AsyncImage(url: show.cover) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 16))
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(show.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let group = show.group, !group.isEmpty, self.group == nil {
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// One row: the search, and the group it is filtered to.
    ///
    /// **The pills are gone.** A strip of them is the right control for five
    /// or ten options — the Videos tab's albums — and the wrong one here: an
    /// Xtream panel hands back hundreds of categories with long names, so the
    /// strip became a scroll inside a scroll in which the one you wanted was
    /// never on screen, and the chip saying where you were was usually
    /// scrolled off it. A button that always reads the current group says the
    /// same thing in a fixed space.
    ///
    /// The field takes the whole row while it is being typed in, and shares it
    /// the rest of the time. A fixed half-and-half wastes the half nobody is
    /// using, and half a row is not enough for "telugu movies" alongside a
    /// glyph and a clear button.
    private var filterRow: some View {
        // The width is needed in the row rather than guessed at, because the
        // one real constraint is proportional: the button may grow to show a
        // long category name, but never past about three fifths, so the field
        // keeps a usable share whatever the provider calls its categories.
        GeometryReader { geo in
            HStack(spacing: 8) {
                searchField.frame(maxWidth: .infinity)
                if !searching, !store.groups.isEmpty {
                    groupButton(within: geo.size.width)
                }
            }
        }
        .frame(height: Self.control)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(chrome)
        .onChange(of: searchFocused) { focused in
            withAnimation(Self.reveal) { searching = focused || !query.isEmpty }
        }
        .sheet(isPresented: $showGroups) {
            IPTVGroupSheet(groups: store.groups, selection: $group)
        }
    }

    /// Both controls are this tall, which is the only way two capsules side by
    /// side look like one row rather than two sizes of button.
    private static let control: CGFloat = 36

    /// The current group, and the way to change it.
    ///
    /// A menu while the list is short enough to read standing up; a searchable
    /// sheet when it is not. Same button either way, so there is one place to
    /// press whatever the provider's category list looks like.
    @ViewBuilder
    private func groupButton(within width: CGFloat) -> some View {
        if store.groups.count <= Self.menuLimit {
            Menu {
                Picker("Group", selection: Binding(
                    get: { group ?? "" },
                    set: { group = $0.isEmpty ? nil : $0 }
                )) {
                    Text("All groups").tag("")
                    ForEach(store.groups, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                groupLabel(within: width)
            }
        } else {
            Button { showGroups = true } label: { groupLabel(within: width) }
                .buttonStyle(.plain)
        }
    }

    /// Reads "All groups" when nothing is chosen — a dropdown has no equivalent
    /// of the highlighted "All" chip, and without it people filter themselves
    /// into a category and cannot find the way back out.
    ///
    /// **`fixedSize`, and the name shortened in code rather than by a frame.**
    /// This is where the gap came from: a `.frame(maxWidth:)` is flexible, so
    /// the stack handed the button its whole maximum and the capsule — which
    /// hugs its text — sat at the trailing end of it with the slack showing as
    /// empty space between the two controls. Capping the *string* instead
    /// leaves the capsule the exact width of what it draws, and the field
    /// takes everything else.
    private func groupLabel(within width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(groupTitle(within: width))
                .font(.caption.weight(group == nil ? .regular : .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(group == nil ? PanuraTheme.onSurfaceVariant : PanuraTheme.onAccentSoft)
        .padding(.horizontal, 12)
        .frame(height: Self.control)
        .background(
            group == nil ? PanuraTheme.surfaceContainerHigh : PanuraTheme.accentSoft,
            in: Capsule()
        )
        .fixedSize()
        .accessibilityLabel("Group: " + (group ?? "all"))
    }

    /// The category name, trimmed to what the row can spare.
    ///
    /// Measured in characters off an estimate of caption width, which is
    /// coarse and is the right kind of coarse: being a few points out moves
    /// the capsule's edge slightly, where being wrong about layout flexibility
    /// put a hole in the middle of the row.
    private func groupTitle(within width: CGFloat) -> String {
        let name = group ?? "All groups"
        // Three fifths of the row for the name, so the field keeps the rest —
        // the chevron, the padding and the gap come out of the button's share
        // before the text does.
        let room = max(0, width * 0.6 - 44)
        let budget = max(6, Int(room / 6.5))
        guard name.count > budget else { return name }
        return String(name.prefix(budget - 1)) + "…"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            TextField(searchPrompt, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            // Clears and closes in one press. Closing without clearing
            // would leave a filtered list with nothing on screen saying why.
            if searching {
                Button {
                    query = ""
                    searchFocused = false
                    withAnimation(Self.reveal) { searching = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.control)
        .background(PanuraTheme.surfaceVariant, in: Capsule())
        .transition(.opacity)
    }

    private var searchPrompt: String {
        switch store.section {
        case .live: return "Search channels"
        case .movies: return "Search films"
        case .series: return "Search series"
        }
    }

    /// A row in list mode.
    ///
    /// The picture was 42 by 32 — small enough that a channel logo was a
    /// smudge and a film poster was unreadable, which is most of why the grid
    /// looked like the only real option. A row is sixty points tall whatever
    /// is in it, so a picture that uses the height costs nothing.
    private func channelRow(_ channel: M3UChannel) -> some View {
        let poster = store.section == .movies
        let state = poster ? watching.watchState(channel.url.absoluteString) : WatchState.unseen
        return HStack(spacing: 12) {
            // The provider's own logo, and nothing drawn in its place while it
            // loads: a channel list is hundreds of rows and a spinner in each
            // one is a screen that looks broken.
            Rectangle()
                .fill(PanuraTheme.surfaceContainerHigh)
                .frame(width: poster ? 46 : 64, height: poster ? 69 : 48)
                .overlay {
                    AsyncImage(url: channel.logo) { phase in
                        if case .success(let image) = phase {
                            if poster {
                                image.resizable().scaledToFill()
                            } else {
                                image.resizable().scaledToFit().padding(5)
                            }
                        } else {
                            Image(systemName: poster ? "film" : "tv")
                                .font(.system(size: 16))
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        }
                    }
                }
                .overlay(alignment: .bottom) { WatchStrip(state: state) }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(
                        state == .finished ? PanuraTheme.onSurfaceVariant : PanuraTheme.onSurface
                    )
                if let group = channel.group, !group.isEmpty, self.group == nil {
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: state == .finished ? "checkmark.circle.fill" : "play.circle")
                .font(.system(size: 18))
                .foregroundStyle(
                    state == .finished ? PanuraTheme.onSurfaceVariant : PanuraTheme.accent
                )
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func play(_ channel: M3UChannel) {
        PlaybackSession.shared.play(
            MediaItem(title: channel.name, url: channel.url, thumbnailURL: channel.logo)
        )
    }
}

/// Every group, searchable.
///
/// For the panel with three hundred categories: a menu would list them all
/// with no way to find one, and the chip strip it replaced was worse. The
/// search here is over group names, not channels — the two are different
/// questions and the row above asks the other one.
private struct IPTVGroupSheet: View {
    let groups: [String]
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [String] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return groups }
        return groups.filter { $0.range(of: text, options: .caseInsensitive) != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                row("All groups", chosen: selection == nil) { selection = nil }
                ForEach(matches, id: \.self) { name in
                    row(name, chosen: selection == name) { selection = name }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PanuraTheme.background)
            .searchable(text: $query, prompt: "Search groups")
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(
        _ name: String, chosen: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PanuraTheme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(PanuraTheme.background)
    }
}

/// Grid or rows.
///
/// Its own type rather than the Videos tab's `Layout`: the same idea about two
/// different screens, and reaching across a feature boundary for an enum of two
/// cases buys a shared name and a dependency nobody wanted.
private enum IPTVLayout: String {
    case grid, list

    /// The glyph for the *other* one — a switch shows where it takes you.
    var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    var next: IPTVLayout { self == .grid ? .list : .grid }
}

/// Pick how the provider hands out access, then fill in that.
///
/// Three choices, though only two code paths: Dispatcharr speaks the Xtream
/// API, so it is the same client with a different host. It still gets its own
/// button, because somebody running Dispatcharr is looking for the word
/// "Dispatcharr" and should not have to know, or be told, that it is Xtream
/// underneath. Naming it is what says they are in the right place.
struct IPTVSourceForm: View {
    @State var source: IPTVSource
    @Binding var password: String
    var onSave: (IPTVSource) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $source.kind) {
                        ForEach(IPTVSource.Kind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(source.kind.detail)
                }

                Section("Playlist") {
                    TextField("Name (optional)", text: $source.name)
                }

                switch source.kind {
                case .xtream, .dispatcharr:
                    Section {
                        TextField("Server", text: $source.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Username", text: $source.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    } header: {
                        Text("Sign in")
                    } footer: {
                        Text(source.kind.help)
                    }

                case .m3u:
                    Section {
                        TextField("M3U address", text: $source.address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } header: {
                        Text("Address")
                    } footer: {
                        Text("The whole address your provider sent, username and password included.")
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    // The line that matters if anybody official ever reads this
                    // screen, and it happens to be true.
                    Text("Panura supplies no channels and cannot help with a subscription. The playlist and everything in it belongs to whoever you got it from.")
                }
            }
            .navigationTitle("Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(source) }
                        .disabled(!source.isComplete)
                }
            }
        }
    }
}

/// One series: its seasons, and the episodes in each.
///
/// A sheet rather than a pushed screen because the list underneath it is where
/// you came from and where you are going back to — and because the IPTV tab
/// draws its own bar, so a navigation stack here would be a second one.
///
/// **It opens where you stopped.** Somebody five episodes into a season does
/// not want to arrive at episode one and scroll; the list lands on the one they
/// were watching, or on the one after the last they finished. That is the whole
/// reason the watched marks exist.
private struct IPTVSeriesSheet: View {
    let show: XtreamSeries

    @ObservedObject private var store = IPTVStore.shared
    @ObservedObject private var watching = BrowsingStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var seasons: [XtreamSeason] = []
    @State private var loading = true
    /// Which season is showing, or nil for all of them — which is the default,
    /// because a list that opens already filtered hides most of what it is for.
    @State private var season: Int?
    /// Remembered across series: somebody who wants the newest episode first
    /// wants it for every series, not for one.
    @AppStorage("iptv_episodes_newest") private var newestFirst = false
    /// The row to open on, worked out once the episodes land.
    @State private var landing: String?

    /// An episode and the season it came from, so a list of all of them can
    /// still say which is which.
    private struct Row: Identifiable {
        let id: String
        let season: Int
        let episode: XtreamEpisode
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if seasons.isEmpty {
                    Text("No episodes listed for this series.")
                        .font(.footnote)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 32)
                } else {
                    list
                }
            }
            .background(PanuraTheme.background)
            .navigationTitle(show.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            seasons = await store.episodes(of: show)
            loading = false
            landing = resumePoint()
        }
    }

    // MARK: the list

    private var rows: [Row] {
        let picked = season.map { number in seasons.filter { $0.number == number } } ?? seasons
        let ascending = flatten(picked)
        return newestFirst ? ascending.reversed() : ascending
    }

    private func flatten(_ list: [XtreamSeason]) -> [Row] {
        list.flatMap { entry in
            entry.episodes.map {
                Row(id: "\(entry.number)x\($0.id)", season: entry.number, episode: $0)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            filterBar
            ScrollViewReader { scroller in
                List(rows) { row in
                    Button { play(row) } label: { episodeRow(row) }
                        .buttonStyle(.plain)
                        .listRowBackground(PanuraTheme.background)
                        .id(row.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: landing) { _ in jump(scroller) }
                .onAppear { jump(scroller) }
            }
        }
    }

    /// Scrolls to the landing row, a beat after the list exists.
    ///
    /// Not immediately: on the pass that creates the list there is nothing to
    /// scroll yet and the proxy quietly does nothing.
    private func jump(_ scroller: ScrollViewProxy) {
        guard let target = landing else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                scroller.scrollTo(target, anchor: .center)
            }
        }
    }

    /// The episode to open on: the one part-way through, else the one after
    /// the last one finished. Nil for a series nobody has started, which opens
    /// at the top like anything else.
    private func resumePoint() -> String? {
        let ascending = flatten(seasons)
        if let partial = ascending.last(where: {
            if case .partial = state(of: $0) { return true }
            return false
        }) {
            return partial.id
        }
        guard let finished = ascending.lastIndex(where: { state(of: $0) == .finished }) else {
            return nil
        }
        let next = finished + 1
        return next < ascending.count ? ascending[next].id : ascending[finished].id
    }

    private func state(of row: Row) -> WatchState {
        watching.watchState(row.episode.url.absoluteString)
    }

    // MARK: the controls

    private var filterBar: some View {
        HStack(spacing: 8) {
            if seasons.count > 1 {
                Menu {
                    Picker("Season", selection: Binding(
                        get: { season ?? -1 },
                        set: { season = $0 < 0 ? nil : $0 }
                    )) {
                        Text("All seasons").tag(-1)
                        ForEach(seasons) { Text("Season \($0.number)").tag($0.number) }
                    }
                } label: {
                    pill(season.map { "Season \($0)" } ?? "All seasons", glyph: "chevron.down")
                }
            }

            Spacer(minLength: 0)

            Menu {
                Picker("Order", selection: $newestFirst) {
                    Text("Oldest first").tag(false)
                    Text("Newest first").tag(true)
                }
            } label: {
                pill(newestFirst ? "Newest first" : "Oldest first", glyph: "arrow.up.arrow.down")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func pill(_ title: String, glyph: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(PanuraTheme.onSurfaceVariant)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(PanuraTheme.surfaceContainerHigh, in: Capsule())
    }

    // MARK: a row

    private func episodeRow(_ row: Row) -> some View {
        let state = state(of: row)
        let done = state == .finished
        return HStack(spacing: 12) {
            still(row, state: state)

            VStack(alignment: .leading, spacing: 3) {
                Text(title(row))
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(done ? PanuraTheme.onSurfaceVariant : PanuraTheme.onSurface)
                // The bar replaces the synopsis rather than joining it: where
                // you stopped is the more useful of the two, and both makes a
                // row tall enough to show three episodes a screen.
                if case .partial(let fraction) = state {
                    ProgressView(value: fraction)
                        .tint(PanuraTheme.accent)
                } else if let plot = row.episode.plot, !plot.isEmpty {
                    Text(plot)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            Image(systemName: done ? "checkmark.circle.fill" : "play.circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? PanuraTheme.onSurfaceVariant : PanuraTheme.accent)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // The way out of a mark the player got wrong — a stream that reports a
        // nonsense duration can finish itself seconds in — and the way to mark
        // an episode watched elsewhere.
        .contextMenu {
            Button {
                if done {
                    watching.unmarkWatched(row.episode.url.absoluteString)
                } else {
                    watching.markWatched(item(row))
                }
            } label: {
                done
                    ? Label("Mark as unwatched", systemImage: "arrow.uturn.backward")
                    : Label("Mark as watched", systemImage: "checkmark.circle")
            }
        }
    }

    private func still(_ row: Row, state: WatchState) -> some View {
        Rectangle()
            .fill(PanuraTheme.surfaceContainerHigh)
            .frame(width: 112, height: 63)
            .overlay {
                AsyncImage(url: row.episode.still) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 18))
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    }
                }
            }
            .overlay(alignment: .bottom) { WatchStrip(state: state) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(state == .finished ? 0.55 : 1)
    }

    /// `S2 E5 · Title` while every season is showing, `5. Title` inside one.
    private func title(_ row: Row) -> String {
        season == nil && seasons.count > 1
            ? "S\(row.season) E\(row.episode.number) · \(row.episode.title)"
            : "\(row.episode.number). \(row.episode.title)"
    }

    /// What gets played, and what a hand-made watched mark records — the same
    /// thing either way, so history and the player agree on the title.
    private func item(_ row: Row) -> MediaItem {
        MediaItem(
            title: "\(show.name) — \(row.episode.title)",
            url: row.episode.url,
            thumbnailURL: row.episode.still
        )
    }

    private func play(_ row: Row) {
        dismiss()
        PlaybackSession.shared.play(item(row))
    }
}
