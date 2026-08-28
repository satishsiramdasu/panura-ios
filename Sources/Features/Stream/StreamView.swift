import SwiftUI

/// Paste-a-URL playback — Android's Network Stream tab, feature for feature:
/// the URL field with paste and clear, advanced options for the two headers a
/// gated CDN checks, a recent list, and the channel browser that appears when a
/// URL turns out to be an M3U playlist rather than one stream.
struct StreamView: View {
    @StateObject private var model = StreamModel()
    @State private var urlText = ""
    @State private var referer = ""
    @State private var userAgent = ""
    @State private var showAdvanced = false
    @State private var playItem: MediaItem?
    @State private var playIndex = 0
    /// Playlist search and group filter.
    @State private var query = ""
    @State private var group: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.playlist != nil { playlistView } else { entryView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(PanuraTheme.background)
            .safeAreaInset(edge: .top, spacing: 0) { PanuraHeader("Network Stream") }
            .navigationBarHidden(true)
        }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0, playlist: channelPlaylist()) }
    }

    // MARK: entry

    private var entryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                urlField

                Button { play() } label: {
                    HStack(spacing: 8) {
                        if model.isLoading {
                            ProgressView().controlSize(.small).tint(PanuraTheme.onAccent)
                            Text("Checking stream…")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(PanuraTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(PanuraTheme.onAccent)
                }
                .buttonStyle(.plain)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || model.isLoading)
                .opacity(urlText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

                advancedOptions
                if !model.history.isEmpty { historySection }
            }
            .padding(16)
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stream URL")
                .font(.caption.weight(.medium))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            HStack(spacing: 6) {
                TextField("https://example.com/master.m3u8", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { play() }
                if urlText.isEmpty {
                    // Pasting is how a stream URL gets here nine times in ten.
                    Button {
                        urlText = UIPasteboard.general.string ?? ""
                    } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.plain)
                        .foregroundStyle(PanuraTheme.accent)
                } else {
                    Button { urlText = ""; model.error = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }
            .padding(14)
            .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(PanuraTheme.error)
            }
        }
    }

    /// The two headers a gated CDN actually checks. Collapsed, because most
    /// links need neither and an open form of empty fields reads as work.
    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Advanced options").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                field("Source page URL", placeholder: "https://site.com/watch/123", text: $referer)
                Text("Sent as the Referer. Many CDNs refuse a stream without the page it belongs to.")
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                field("User-Agent", placeholder: "Mozilla/5.0 …", text: $userAgent)
            }
        }
        .padding(14)
        .background(PanuraTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 12))
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(PanuraTheme.onSurfaceVariant)
            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !text.wrappedValue.isEmpty {
                    Button { text.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
            }
            .padding(12)
            .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Recent", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                Spacer()
                Button("Clear all") { model.clearHistory() }
                    .font(.caption)
            }
            ForEach(model.history, id: \.self) { entry in
                Button {
                    urlText = entry
                    play()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.footnote)
                            .foregroundStyle(PanuraTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(string: entry)?.host ?? entry)
                                .font(.subheadline).lineLimit(1)
                            Text(entry)
                                .font(.caption2)
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { model.remove(entry) } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(PanuraTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: playlist

    private var filteredChannels: [M3UChannel] {
        guard let playlist = model.playlist else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return playlist.channels.filter { channel in
            (group == nil || channel.group == group)
                && (q.isEmpty || channel.name.lowercased().contains(q))
        }
    }

    @ViewBuilder
    private var playlistView: some View {
        if let playlist = model.playlist {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        model.clearPlaylist()
                        query = ""
                        group = nil
                    } label: { Image(systemName: "arrow.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(PanuraTheme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Playlist").font(.subheadline.weight(.bold))
                        Text(
                            "\(playlist.channels.count) channels"
                                + (filteredChannels.count != playlist.channels.count
                                   ? " · \(filteredChannels.count) shown" : "")
                        )
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    TextField("Search playlist…", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(PanuraTheme.surfaceVariant, in: Capsule())
                .padding(.horizontal, 16)

                if !playlist.groups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            groupChip(nil, label: "All")
                            ForEach(playlist.groups, id: \.self) { groupChip($0, label: $0) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }

                List {
                    ForEach(Array(filteredChannels.enumerated()), id: \.element.id) { index, channel in
                        Button { playChannel(channel, at: index) } label: {
                            HStack(spacing: 12) {
                                if let logo = channel.logo {
                                    AsyncImage(url: logo) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        Image(systemName: "tv").foregroundStyle(PanuraTheme.onSurfaceVariant)
                                    }
                                    .frame(width: 34, height: 34)
                                } else {
                                    Image(systemName: "tv")
                                        .frame(width: 34)
                                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.name).font(.subheadline).lineLimit(1)
                                    if let group = channel.group {
                                        Text(group)
                                            .font(.caption2)
                                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func groupChip(_ value: String?, label: String) -> some View {
        Button { group = value } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    Capsule().fill(group == value ? PanuraTheme.accentSoft : PanuraTheme.surfaceVariant)
                )
                .foregroundStyle(group == value ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
        }
        .buttonStyle(.plain)
    }

    // MARK: playback

    private var headers: [String: String] {
        var headers: [String: String] = [:]
        let page = self.referer.trimmingCharacters(in: .whitespaces)
        let ua = userAgent.trimmingCharacters(in: .whitespaces)
        if !page.isEmpty { headers["Referer"] = page }
        if !ua.isEmpty { headers["User-Agent"] = ua }
        return headers
    }

    private func play() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard let raw = URL(string: trimmed), !model.isLoading else { return }
        // Pasted links and .m3u entries commonly carry the gate as
        // `…/master.m3u8#referer=https%3A%2F%2Fsite.com`.
        let (url, fragmentReferer) = RefererFragment.split(raw)
        var headers = self.headers
        if let fragmentReferer { headers["Referer"] = fragmentReferer }

        model.error = nil
        Task {
            // A .m3u is usually a channel list, and playing it as one stream
            // hands the user whichever channel happens to be first. Only the
            // body can tell a list from a stream, so it is read before playing.
            let isPlaylistCandidate = url.pathExtension.lowercased() == "m3u"
                || url.absoluteString.lowercased().contains(".m3u?")
                || url.pathExtension.lowercased() == "m3u8"
            if isPlaylistCandidate, await model.loadPlaylistIfAny(url, headers: headers) {
                model.remember(trimmed)
                return
            }
            model.remember(trimmed)
            playItem = MediaItem(title: url.lastPathComponent, url: url, headers: headers)
        }
    }

    private func playChannel(_ channel: M3UChannel, at index: Int) {
        playIndex = index
        playItem = MediaItem(title: channel.name, url: channel.url, headers: headers)
    }

    /// Next/previous walks the channel list as filtered on screen, so the order
    /// in the player is the order that was being looked at.
    private func channelPlaylist() -> PlayerPlaylist? {
        let channels = filteredChannels
        guard channels.count > 1 else { return nil }
        let headers = self.headers
        return PlayerPlaylist(count: channels.count, startIndex: playIndex) { i in
            guard i >= 0, i < channels.count else { return nil }
            return MediaItem(title: channels[i].name, url: channels[i].url, headers: headers)
        }
    }
}
