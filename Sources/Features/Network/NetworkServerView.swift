import SwiftUI

/// Files on a server somebody owns: SMB, SFTP or FTP.
///
/// Two states, one screen. With nothing open it is the list of servers that
/// have been set up, plus a way to add one. With something open it is a
/// directory listing with a breadcrumb. There is no separate "connect" step
/// because there is nothing to confirm — opening a server *is* listing it, and
/// a connect screen that succeeds and then shows you another screen is a step
/// that exists only to be got past.
struct NetworkServerView: View {
    @StateObject private var browser = NetworkBrowser()
    @ObservedObject private var store = NetworkServerStore.shared
    @Environment(\.screenChrome) private var chrome

    @State private var editing: NetworkServer?
    @State private var editingPassword = ""

    var body: some View {
        Group {
            if browser.levels.isEmpty { serverList } else { listing }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PanuraTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) { bar }
        .sheet(item: $editing) { server in
            NetworkServerForm(
                server: server,
                password: $editingPassword,
                onSave: { edited in
                    store.save(edited, password: editingPassword)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    // MARK: bar

    private var bar: some View {
        HStack(spacing: 10) {
            if browser.levels.count > 1 {
                button("chevron.left", label: "Up a folder") { browser.up() }
            } else if !browser.levels.isEmpty {
                button("xmark", label: "Close server") { browser.close() }
            }

            Text(browser.levels.last?.name ?? "Servers")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if browser.levels.isEmpty {
                button("plus", label: "Add a server") {
                    editingPassword = ""
                    editing = NetworkServer()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(chrome)
    }

    private func button(_ glyph: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: servers

    @ViewBuilder
    private var serverList: some View {
        if store.servers.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 40))
                    .foregroundStyle(PanuraTheme.accent)
                Text("No servers yet")
                    .font(.headline)
                Text("Add a NAS, a router or anything on your network that shares files over SMB, SFTP or FTP. Nothing is uploaded and nothing leaves your network.")
                    .font(.footnote)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        } else {
            List {
                ForEach(store.servers) { server in
                    Button {
                        browser.open(server, password: store.password(for: server))
                    } label: {
                        row(server)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(PanuraTheme.background)
                    .swipeActions {
                        Button(role: .destructive) { store.remove(server) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        Button {
                            editingPassword = store.password(for: server)
                            editing = server
                        } label: { Label("Edit", systemImage: "pencil") }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ server: NetworkServer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 17))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 38, height: 38)
                .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(server.scheme.label) · \(server.host)\(server.path)")
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
        .padding(.vertical, 4)
    }

    // MARK: listing

    @ViewBuilder
    private var listing: some View {
        VStack(spacing: 0) {
            crumbs
            if browser.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading the folder…")
                        .font(.footnote)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = browser.failure, browser.entries.isEmpty {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 32)
            } else {
                // A `ScrollView` and a `LazyVStack` rather than a `List`, for
                // one reason: the header and the tab strip slide away as this
                // is scrolled, and the probe that measures it has to find a
                // `UIScrollView` by walking up from inside the content. A
                // `List` recycles its rows, so a probe in one of them attaches
                // and detaches as you scroll. Nothing else is lost — this
                // listing has no swipe actions, unlike the server list above.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(browser.entries) { entry in
                            VStack(spacing: 0) {
                                Button { open(entry) } label: { entryRow(entry) }
                                    .buttonStyle(.plain)
                                Divider().overlay(PanuraTheme.outlineVariant)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .scrollAwayChrome(.ftp)
                }
            }
        }
    }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(browser.levels) { level in
                    if level != browser.levels.first {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    }
                    Button { browser.go(to: level) } label: {
                        Text(level.name)
                            .font(.caption.weight(level == browser.levels.last ? .semibold : .regular))
                            .foregroundStyle(
                                level == browser.levels.last
                                    ? PanuraTheme.onSurface : PanuraTheme.onSurfaceVariant
                            )
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func entryRow(_ entry: NetworkBrowser.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "play.rectangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(entry.isDirectory ? PanuraTheme.tertiary : PanuraTheme.accent)
                .frame(width: 30)
            Text(entry.name)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 8)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
        }
        .padding(.vertical, 6)
    }

    private func open(_ entry: NetworkBrowser.Entry) {
        if entry.isDirectory {
            browser.enter(entry)
        } else {
            PlaybackSession.shared.play(NetworkBrowser.item(for: entry))
        }
    }
}

/// Host, credentials, and where to start.
private struct NetworkServerForm: View {
    @State var server: NetworkServer
    @Binding var password: String
    var onSave: (NetworkServer) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $server.scheme) {
                        ForEach(NetworkServer.Scheme.allCases) { scheme in
                            Text(scheme.label).tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(server.scheme.detail)
                }

                Section("Server") {
                    TextField("Name (optional)", text: $server.name)
                    TextField("Address or IP", text: $server.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField(
                        "Port (default \(server.scheme.defaultPort))",
                        value: $server.port,
                        format: .number
                    )
                    .keyboardType(.numberPad)
                    TextField("Folder or share", text: $server.path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Username", text: $server.user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } header: {
                    Text("Sign in")
                } footer: {
                    // Said plainly because it is the one thing people hesitate
                    // over, and because it is true: see `Keychain`.
                    Text("Leave both empty for a guest or anonymous server. The password is kept in the iOS keychain on this device and is never sent anywhere but to this server.")
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(server) }
                        .disabled(server.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
