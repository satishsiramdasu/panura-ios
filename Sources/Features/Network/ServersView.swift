import SwiftUI

/// Everything you sign into, in one place.
///
/// A NAS over SMB or SFTP, a playlist address, an Xtream or Dispatcharr
/// account — and, when they arrive, Jellyfin and the rest. They were two tabs,
/// and the split was never one a person could reason about: both are *an
/// address, a username, a password, and a list that comes back*. Which tab a
/// thing belonged to was a question only the app's own history could answer.
///
/// Three states, one screen, and the state is wherever you last were:
///
/// - Nothing open — the sources you have added, and the `+` that adds one.
/// - A playlist open — `IPTVView`, which draws channels, films and series.
/// - A folder open — `NetworkServerView`, which draws a directory listing.
///
/// Neither of those two draws its own list of sources any more, because it
/// never gets the chance: this screen only hands over once something is open,
/// and takes back over the moment it closes. That is also why the browse state
/// moved to `NetworkBrowser.shared` — the question "is a folder open?" is now
/// asked from above as well as inside.
struct ServersView: View {
    @ObservedObject private var iptv = IPTVStore.shared
    @ObservedObject private var browser = NetworkBrowser.shared
    @ObservedObject private var servers = NetworkServerStore.shared
    @Environment(\.screenChrome) private var chrome

    @State private var editingSource: IPTVSource?
    @State private var editingPassword = ""
    @State private var editingServer: NetworkServer?
    @State private var serverPassword = ""

    var body: some View {
        Group {
            if iptv.open != nil {
                IPTVView()
            } else if !browser.levels.isEmpty {
                NetworkServerView()
            } else {
                home
            }
        }
        .sheet(item: $editingSource) { source in
            IPTVSourceForm(
                source: source,
                password: $editingPassword,
                onSave: { edited in
                    iptv.save(edited, password: editingPassword)
                    editingSource = nil
                    Task { await iptv.load(edited, force: true) }
                },
                onCancel: { editingSource = nil }
            )
        }
        .sheet(item: $editingServer) { server in
            NetworkServerForm(
                server: server,
                password: $serverPassword,
                onSave: { edited in
                    servers.save(edited, password: serverPassword)
                    editingServer = nil
                },
                onCancel: { editingServer = nil }
            )
        }
    }

    // MARK: the list of sources

    private var home: some View {
        Group {
            if iptv.sources.isEmpty && servers.servers.isEmpty { empty } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PanuraTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) { bar }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Text("Servers")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            addMenu("Add")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(chrome)
    }

    /// One menu for every kind, grouped by what the thing is rather than by
    /// what protocol it speaks: a playlist server hands back a list of
    /// channels, a file server hands back folders. Media servers — Jellyfin,
    /// Plex, Emby — are the third group when they arrive, and they go in here
    /// rather than anywhere else for the same reason these two did.
    private func addMenu(_ title: String, filled: Bool = false) -> some View {
        Menu {
            Section("Playlist server") {
                Button("M3U") { addSource(.m3u) }
                Button("Xtream") { addSource(.xtream) }
                Button("Dispatcharr") { addSource(.dispatcharr) }
            }
            Section("File server") {
                Button("SMB share") { addServer(.smb) }
                Button("SFTP") { addServer(.sftp) }
                Button("FTP") { addServer(.ftp) }
            }
        } label: {
            // A word, not a `+`. The plus is the right glyph where what gets
            // added is obvious from the screen — one more of the thing you are
            // already looking at. Here it opens a menu of six kinds across two
            // groups, and on an empty screen there is nothing to be one more
            // of, so the button has to say what it does.
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(filled ? PanuraTheme.onAccent : PanuraTheme.accent)
            .padding(.horizontal, filled ? 18 : 10)
            .padding(.vertical, filled ? 10 : 6)
            .background(filled ? PanuraTheme.accent : .clear, in: Capsule())
            .contentShape(Capsule())
        }
    }

    private var list: some View {
        List {
            if !iptv.sources.isEmpty {
                Section("Playlist servers") {
                    ForEach(iptv.sources) { source in
                        Button { Task { await iptv.load(source) } } label: {
                            row(
                                title: source.displayName,
                                detail: detail(for: source),
                                glyph: "list.and.film",
                                badge: source.kind.label
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(PanuraTheme.background)
                        .swipeActions {
                            // Tinted by hand. A swipe action takes the app's
                            // accent unless told otherwise, so the two came
                            // out the same amber — Remove not reading as
                            // destructive, and a white pencil nearly invisible
                            // on it.
                            Button(role: .destructive) { iptv.remove(source) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .tint(.red)
                            Button {
                                editingPassword = iptv.password(for: source)
                                editingSource = source
                            } label: { Label("Edit", systemImage: "pencil") }
                                .tint(PanuraTheme.outline)
                        }
                    }
                }
            }

            if !servers.servers.isEmpty {
                Section("File servers") {
                    ForEach(servers.servers) { server in
                        Button {
                            browser.open(server, password: servers.password(for: server))
                        } label: {
                            row(
                                title: server.displayName,
                                detail: server.subtitle,
                                glyph: "externaldrive.fill",
                                badge: server.scheme.label
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(PanuraTheme.background)
                        .swipeActions {
                            Button(role: .destructive) { servers.remove(server) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .tint(.red)
                            Button {
                                serverPassword = servers.password(for: server)
                                editingServer = server
                            } label: { Label("Edit", systemImage: "pencil") }
                                .tint(PanuraTheme.outline)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// A playlist row's tagline: where it points, and when it last updated.
    ///
    /// The age is the reason this row exists rather than just a name. A
    /// playlist is somebody else's list and it changes without warning, so
    /// "updated 3 days ago" is both the answer to "why is that channel
    /// missing" and the thing that makes the Refresh inside worth pressing.
    /// It is read here rather than inside the server because it is a question
    /// asked while *choosing* between servers.
    ///
    /// `ServerRefresh`'s clock, not the catalogue's fetch time: that one is
    /// reset by the automatic three-hour refetch, so it would read "moments
    /// ago" for a list nobody has deliberately refreshed in a week. This is
    /// the clock the 24-hour wall counts down, which makes the row and the
    /// wall agree.
    private func detail(for source: IPTVSource) -> String {
        guard let age = ServerRefresh.ageDescription(source.id, style: .short) else {
            return source.subtitle
        }
        return source.subtitle + " · updated " + age
    }

    /// One row shape for both kinds, with the kind said in a badge rather than
    /// left to the icon. Two rows that open completely different screens should
    /// not be told apart by a glyph alone.
    private func row(
        title: String, detail: String, glyph: String, badge: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 17))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 38, height: 38)
                .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(PanuraTheme.surfaceContainerHigh, in: Capsule())
                }
                Text(detail)
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
        // A `Spacer` draws nothing and so is nothing to hit: without a shape
        // of its own the row answered on the title and the chevron and was
        // dead in between, which is most of its width.
        .contentShape(Rectangle())
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 40))
                .foregroundStyle(PanuraTheme.accent)
            Text("Nothing added yet")
                .font(.headline)
            // Three kinds, named the way the Add menu names them. "IPTV
            // account" was the old wording and it said the wrong thing twice:
            // the menu calls these playlist servers, and "IPTV" describes a
            // category of service rather than the thing being added, which is
            // either an address or an account.
            Text("""
            Add a file server that speaks SMB, SFTP or FTP — a NAS in the \
            house, or a machine anywhere else. Or a direct M3U playlist \
            address. Or sign in to a playlist server account you already have.
            """)
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)

            // Its own line, because it is its own point. Run on to the end of
            // the list above, it read as a footnote to the last kind rather
            // than as what it is: the one sentence that says what this app is
            // and is not, on the screen where somebody is deciding what to
            // expect from it.
            Text("Panura supplies none of it — it opens what you enter, and nothing else.")
                .font(.caption)
                .foregroundStyle(PanuraTheme.onSurfaceVariant.opacity(0.85))
                .multilineTextAlignment(.center)
            addMenu("Add a server", filled: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func addSource(_ kind: IPTVSource.Kind) {
        editingPassword = ""
        var source = IPTVSource()
        source.kind = kind
        editingSource = source
    }

    private func addServer(_ scheme: NetworkServer.Scheme) {
        serverPassword = ""
        var server = NetworkServer()
        server.scheme = scheme
        editingServer = server
    }
}
