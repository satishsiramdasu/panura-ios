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

    @State private var query = ""
    @State private var group: String?
    @State private var editing: IPTVSource?
    @State private var editingPassword = ""
    @State private var openSeries: XtreamSeries?

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
            search
            if !store.groups.isEmpty { groupStrip }

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
                List(visible) { channel in
                    Button { play(channel) } label: { channelRow(channel) }
                        .buttonStyle(.plain)
                        .listRowBackground(PanuraTheme.background)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
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
            List(visibleSeries) { show in
                Button { openSeries = show } label: { seriesRow(show) }
                    .buttonStyle(.plain)
                    .listRowBackground(PanuraTheme.background)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            TextField(searchPrompt, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(PanuraTheme.surfaceVariant, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(chrome)
    }

    private var searchPrompt: String {
        switch store.section {
        case .live: return "Search channels"
        case .movies: return "Search films"
        case .series: return "Search series"
        }
    }

    private var groupStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", active: group == nil) { group = nil }
                ForEach(store.groups, id: \.self) { name in
                    chip(name, active: group == name) { group = name }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(chrome)
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(active ? PanuraTheme.onAccentSoft : PanuraTheme.onSurfaceVariant)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    active ? PanuraTheme.accentSoft : PanuraTheme.surfaceContainerHigh,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
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
            AsyncImage(url: episode.still) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 14))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }
            .frame(width: 56, height: 32)
            .clipped()
            .background(PanuraTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
