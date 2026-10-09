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

    var body: some View {
        Group {
            if store.open == nil { sourceList } else { channelList }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PanuraTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) { bar }
        .sheet(item: $editing) { source in
            IPTVSourceForm(
                source: source,
                onSave: { edited in
                    store.save(edited)
                    editing = nil
                    Task { await store.load(edited) }
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
                glyph("plus", label: "Add a playlist") { editing = IPTVSource() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(chrome)
    }

    /// How many channels, and how old they are. The age matters here in a way
    /// it does not elsewhere: a playlist is somebody else's list and it changes
    /// without warning, so "loaded an hour ago" is the answer to "why is that
    /// channel missing".
    private var subtitle: String {
        var parts = ["\(store.channels.count) channels"]
        if let at = store.fetchedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append(formatter.localizedString(for: at, relativeTo: Date()))
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
                Text("Add the M3U address your provider gave you. Panura ships no channels of its own — it opens the playlist you enter, and nothing else.")
                    .font(.footnote)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                Button { editing = IPTVSource() } label: {
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
                        Button { editing = source } label: {
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
                Text(source.address)
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
        return store.channels.filter { channel in
            if let group, channel.group != group { return false }
            guard !text.isEmpty else { return true }
            return channel.name.range(of: text, options: .caseInsensitive) != nil
        }
    }

    @ViewBuilder
    private var channelList: some View {
        VStack(spacing: 0) {
            search
            if !store.groups.isEmpty { groupStrip }

            if store.channels.isEmpty {
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

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            TextField("Search channels", text: $query)
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

/// Name and address. Two fields, because a playlist is two facts.
private struct IPTVSourceForm: View {
    @State var source: IPTVSource
    var onSave: (IPTVSource) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    TextField("Name (optional)", text: $source.name)
                    TextField("M3U address", text: $source.address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Paste the address your provider gave you. Panura does not supply channels and cannot help with a subscription — the playlist and everything in it belongs to whoever you got it from.")
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
                        .disabled(source.url == nil || source.address.isEmpty)
                }
            }
        }
    }
}
