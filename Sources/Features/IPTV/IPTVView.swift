import SwiftUI

/// Live channels from a playlist somebody subscribes to.
///
/// Panura ships no playlists and no channels. It opens the address its owner
/// enters, exactly as the browser opens the address its owner types — which is
/// both the honest design and the one that does not put this app in the
/// business of distributing someone else's broadcast.
///
/// Two states on one screen, like the Server tab: the playlists that have been
/// added, or the channels inside one.
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

    @State private var query = ""
    @State private var group: String?
    @State private var editing: IPTVSource?
    @State private var editingPassword = ""
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
        Group {
            if store.open == nil { sourceList } else { channelList }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PanuraTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) { bar }
        .sheet(item: $openSeries) { show in
            IPTVSeriesSheet(show: show)
        }
        .sheet(item: $editing) { source in
            IPTVSourceForm(
                source: source,
                password: $editingPassword,
                onSave: { edited in
                    store.save(edited, password: editingPassword)
                    editing = nil
                    // Forced: the credentials just changed, so whatever is in
                    // the cache was fetched with the old ones.
                    Task { await store.load(edited, force: true) }
                },
                onCancel: { editing = nil }
            )
        }
    }

    // MARK: bar

    private var bar: some View {
        HStack(spacing: 10) {
            if store.open != nil {
                glyph("chevron.left", label: "All playlists") {
                    store.close()
                    query = ""
                    group = nil
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(store.open?.displayName ?? "IPTV")
                    .font(.headline)
                    .lineLimit(1)
                if store.open != nil, !store.channels.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let open = store.open {
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
                } else {
                    glyph("arrow.clockwise", label: "Reload channels") {
                        Task { await store.load(open, force: true) }
                    }
                }
            } else {
                glyph("plus", label: "Add a playlist") { addPlaylist() }
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

    private func addPlaylist() {
        editingPassword = ""
        editing = IPTVSource()
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

    // MARK: playlists

    @ViewBuilder
    private var sourceList: some View {
        if store.sources.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tv.badge.wifi")
                    .font(.system(size: 40))
                    .foregroundStyle(PanuraTheme.accent)
                Text("No playlist yet")
                    .font(.headline)
                Text("Sign in to an Xtream or Dispatcharr server, or paste an M3U address. Panura ships no channels of its own — it opens the playlist you enter, and nothing else.")
                    .font(.footnote)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                Button { addPlaylist() } label: {
                    Text("Add a playlist")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PanuraTheme.onAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(PanuraTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        } else {
            List {
                ForEach(store.sources) { source in
                    Button { Task { await store.load(source) } } label: {
                        sourceRow(source)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(PanuraTheme.background)
                    .swipeActions {
                        Button(role: .destructive) { store.remove(source) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        Button {
                            editingPassword = store.password(for: source)
                            editing = source
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func sourceRow(_ source: IPTVSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "list.and.film")
                .font(.system(size: 17))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 38, height: 38)
                .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(source.subtitle)
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
        .padding(.vertical, 4)
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
                        .scrollAwayChrome(.iptv)
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
        return VStack(alignment: .leading, spacing: 6) {
            artwork(channel.logo, poster: poster, fallback: poster ? "film" : "tv")
            Text(channel.name)
                .font(.caption)
                // Reserved rather than merely limited: without it a one-line
                // name and a two-line name make two different row heights, and
                // the grid develops a ragged baseline down the screen.
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The picture part of a tile, at whichever of the two shapes.
    ///
    /// An `overlay` on the fill, never a `ZStack` sibling: `scaledToFill`
    /// reports a layout size larger than its box in one axis, so as a sibling
    /// it grows the stack and the tile stops being the shape it was told to be.
    /// Learned here once already — see `Thumbnail` in the Videos tab.
    private func artwork(_ url: URL?, poster: Bool, fallback: String) -> some View {
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
                Text(store.failure ?? "No series in this subscription.")
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
                    .scrollAwayChrome(.iptv)
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
                    // Always a poster, in both sections that have one: a series
                    // is sold by its cover exactly as a film is.
                    artwork(show.cover, poster: true, fallback: "rectangle.stack")
                    Text(show.name)
                        .font(.caption)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            AsyncImage(url: show.cover) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 14))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }
            .frame(width: 38, height: 54)
            .clipped()
            .background(PanuraTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
        HStack(spacing: 8) {
            // The field is the one that gives way. It used to hold the
            // priority, which a `TextField` spends by taking every point on
            // offer — so the group button was squeezed to its chevron and the
            // chosen category, which it was drawing all along, had nowhere to
            // appear. The name is the whole reason the button exists, so the
            // name is sized first and the field takes what is left.
            searchField.frame(minWidth: 120)
            if !searching, !store.groups.isEmpty {
                groupButton.layoutPriority(1)
            }
        }
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

    /// The current group, and the way to change it.
    ///
    /// A menu while the list is short enough to read standing up; a searchable
    /// sheet when it is not. Same button either way, so there is one place to
    /// press whatever the provider's category list looks like.
    @ViewBuilder
    private var groupButton: some View {
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
                groupLabel
            }
        } else {
            Button { showGroups = true } label: { groupLabel }
                .buttonStyle(.plain)
        }
    }

    /// Reads "All groups" when nothing is chosen — a dropdown has no equivalent
    /// of the highlighted "All" chip, and without it people filter themselves
    /// into a category and cannot find the way back out.
    private var groupLabel: some View {
        HStack(spacing: 4) {
            Text(group ?? "All groups")
                .font(.caption.weight(group == nil ? .regular : .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(group == nil ? PanuraTheme.onSurfaceVariant : PanuraTheme.onAccentSoft)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            group == nil ? PanuraTheme.surfaceContainerHigh : PanuraTheme.accentSoft,
            in: Capsule()
        )
        // Roughly half the row on a phone, and never more: enough for two
        // or three words of a category name, with the rest trimmed. A name
        // that fits takes only what it needs.
        .frame(maxWidth: 168, alignment: .trailing)
        .accessibilityLabel("Group: " + (group ?? "all"))
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
        .padding(.vertical, 6)
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

    private func channelRow(_ channel: M3UChannel) -> some View {
        HStack(spacing: 12) {
            // The provider's own logo, and nothing drawn in its place while it
            // loads: a channel list is hundreds of rows and a spinner in each
            // one is a screen that looks broken.
            AsyncImage(url: channel.logo) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 14))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }
            .frame(width: 42, height: 32)
            .background(PanuraTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if let group = channel.group, !group.isEmpty, self.group == nil {
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "play.circle")
                .font(.system(size: 18))
                .foregroundStyle(PanuraTheme.accent)
        }
        .padding(.vertical, 4)
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
private struct IPTVSourceForm: View {
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
private struct IPTVSeriesSheet: View {
    let show: XtreamSeries

    @ObservedObject private var store = IPTVStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var seasons: [XtreamSeason] = []
    @State private var loading = true
    /// Which season is open. The first by default — a series with one season
    /// should not need a tap to show it.
    @State private var season: Int?

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
            season = seasons.first?.number
            loading = false
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(seasons) { entry in
                            Button { season = entry.number } label: {
                                Text("Season \(entry.number)")
                                    .font(.caption.weight(season == entry.number ? .semibold : .regular))
                                    .foregroundStyle(
                                        season == entry.number
                                            ? PanuraTheme.onAccentSoft : PanuraTheme.onSurfaceVariant
                                    )
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        season == entry.number
                                            ? PanuraTheme.accentSoft : PanuraTheme.surfaceContainerHigh,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            List(episodes) { episode in
                Button { play(episode) } label: { row(episode) }
                    .buttonStyle(.plain)
                    .listRowBackground(PanuraTheme.background)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var episodes: [XtreamEpisode] {
        seasons.first { $0.number == season }?.episodes ?? seasons.first?.episodes ?? []
    }

    private func row(_ episode: XtreamEpisode) -> some View {
        HStack(spacing: 12) {
            // Big enough to be a picture rather than a bullet point. A still is
            // the only thing that distinguishes one episode from the next when
            // the panel leaves the titles empty, which it routinely does, and
            // at thumbnail size it was doing that job for nobody.
            Rectangle()
                .fill(PanuraTheme.surfaceContainerHigh)
                .frame(width: 112, height: 63)
                .overlay {
                    AsyncImage(url: episode.still) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 18))
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(episode.number). \(episode.title)")
                    .font(.subheadline)
                    .lineLimit(1)
                if let plot = episode.plot, !plot.isEmpty {
                    Text(plot)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "play.circle")
                .font(.system(size: 18))
                .foregroundStyle(PanuraTheme.accent)
        }
        .padding(.vertical, 4)
    }

    private func play(_ episode: XtreamEpisode) {
        dismiss()
        PlaybackSession.shared.play(
            MediaItem(
                title: "\(show.name) — \(episode.title)",
                url: episode.url,
                thumbnailURL: episode.still
            )
        )
    }
}
