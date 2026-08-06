import SwiftUI

struct BrowserView: View {
    /// Address handed over from Home. Cleared once loaded so the same entry
    /// isn't replayed on every tab switch.
    @Binding var pendingAddress: String?

    @StateObject private var model = BrowserModel()
    @ObservedObject private var store = BrowsingStore.shared
    @ObservedObject private var panuraCast = PanuraCastManager.shared
    @EnvironmentObject private var cast: CastManager
    @State private var addressText = ""
    @State private var playItem: MediaItem?
    @State private var showFoundSheet = false
    @State private var showPanuraControls = false
    @State private var editingAddress = false
    @AppStorage("debug_detection") private var debugDetection = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            progressBar
            WebViewContainer(model: model)
        }
        .safeAreaInset(edge: .bottom) {
            // With diagnostics on the bar must also open when nothing was
            // detected — that is precisely the case worth inspecting.
            if !model.foundVideos.isEmpty || (debugDetection && !model.debugLog.isEmpty) {
                foundBar
            }
        }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0) }
        .sheet(isPresented: $showPanuraControls) { PanuraCastControlView() }
        .sheet(isPresented: $showFoundSheet) { foundSheet }
        .onChange(of: model.currentURL) { url in
            if let url, !editingAddress { addressText = url.absoluteString }
            if let url { store.recordVisit(url: url, title: model.pageTitle) }
        }
        // Record again when the title lands — WebKit fires it after didFinish, so
        // the first write usually has an empty title.
        .onChange(of: model.pageTitle) { title in
            if let url = model.currentURL, !title.isEmpty {
                store.recordVisit(url: url, title: title)
            }
        }
        .onChange(of: pendingAddress) { _ in consumePending() }
        .onAppear { consumePending() }
    }

    /// Load whatever Home handed over, then clear it.
    private func consumePending() {
        guard let address = pendingAddress, !address.isEmpty else { return }
        pendingAddress = nil
        editingAddress = false
        addressText = address
        model.load(address)
    }

    // MARK: address bar

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.footnote)

            TextField("Search or enter address", text: $addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit {
                    editingAddress = false
                    model.load(addressText)
                }

            if model.isLoading {
                Button { model.stop() } label: {
                    Image(systemName: "xmark").font(.footnote)
                }
            } else if model.currentURL != nil {
                Button { model.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.footnote)
                }
            }

            menu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PanuraTheme.accentSoft, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var menu: some View {
        Menu {
            Button {
                model.goBack()
            } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)

            Button {
                model.goForward()
            } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)

            Button { model.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }

            Divider()

            Button { model.toggleDesktopMode() } label: {
                Label(
                    model.desktopMode ? "Request mobile site" : "Request desktop site",
                    systemImage: model.desktopMode ? "iphone" : "desktopcomputer"
                )
            }

            if let url = model.currentURL {
                let key = url.absoluteString
                Button {
                    if store.isShortcut(key) {
                        store.removeShortcut(url: key)
                    } else {
                        store.addShortcut(
                            url: key,
                            title: model.pageTitle.isEmpty ? (url.host ?? key) : model.pageTitle
                        )
                    }
                } label: {
                    Label(
                        store.isShortcut(key) ? "Remove shortcut" : "Add to shortcuts",
                        systemImage: store.isShortcut(key) ? "star.fill" : "star"
                    )
                }

                Button {
                    UIPasteboard.general.string = url.absoluteString
                } label: { Label("Copy link", systemImage: "doc.on.doc") }

                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }

                Button {
                    UIApplication.shared.open(url)
                } label: { Label("Open in Safari", systemImage: "safari") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.footnote)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if model.isLoading, model.progress < 1 {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(PanuraTheme.accent)
                .frame(height: 2)
        }
    }

    // MARK: detected videos

    private var foundBar: some View {
        Button { showFoundSheet = true } label: {
            HStack(spacing: 10) {
                Image(systemName: model.foundVideos.isEmpty ? "ladybug.fill" : "play.rectangle.fill")
                Text(
                    model.foundVideos.isEmpty
                        ? "Sniffer log (\(model.debugLog.count))"
                        : "\(model.foundVideos.count) video\(model.foundVideos.count == 1 ? "" : "s") found"
                )
                .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.up").font(.footnote)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(PanuraTheme.accent, in: Capsule())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var foundSheet: some View {
        NavigationStack {
            List {
                ForEach(model.foundVideos) { video in
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.title.isEmpty ? "Video" : video.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(video.url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        Button {
                            showFoundSheet = false
                            playItem = model.playable(video)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PanuraTheme.accent)

                        if cast.isConnected {
                            Button {
                                showFoundSheet = false
                                cast.cast(model.playable(video))
                            } label: {
                                Label("Cast", systemImage: "tv")
                            }
                            .buttonStyle(.bordered)
                        }

                        if panuraCast.isTVConnected {
                            Button {
                                showFoundSheet = false
                                panuraCast.cast(model.playable(video))
                                showPanuraControls = true
                            } label: {
                                Label("Panura TV", systemImage: "appletv.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.vertical, 4)
                }

                if debugDetection {
                    Section {
                        ForEach(model.debugLog) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(entry.source) → \(entry.verdict)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(
                                        entry.verdict.hasPrefix("emitted") ? Color.green : .secondary
                                    )
                                Text(entry.host)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(entry.url)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Text("Sniffer log (\(model.debugLog.count))")
                            Spacer()
                            Button("Copy") {
                                UIPasteboard.general.string = model.debugLogText
                            }
                            .font(.caption)
                        }
                    } footer: {
                        Text("Every media-shaped URL the page requested and what the sniffer decided. Turn off in Settings.")
                    }
                }
            }
            .navigationTitle("Detected videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showFoundSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
