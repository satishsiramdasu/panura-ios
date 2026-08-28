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
    /// Asked when private browsing is switched OFF with a page still open — the
    /// session is live and is about to start being recorded again.
    @State private var confirmLeavingPrivate = false
    @AppStorage("debug_detection") private var debugDetection = false
    /// Only read to rebuild the web view when it changes: user scripts are fixed
    /// at creation, so a toggle in Settings means nothing until a new one exists.
    @AppStorage("auto_play_click") private var autoPlayClick = true

    /// Deliberately not the app accent, which the address pill already wears:
    /// a private session has to be visible at a glance, and a slightly different
    /// purple would read as the same pill. A cool slate reads as "not normal".
    private static let privateTint = Color(red: 0.24, green: 0.28, blue: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            progressBar
            WebViewContainer(model: model)
                // A data store cannot be swapped on a live web view, so private
                // mode gets a new one. Rebuilding also drops the back list and
                // the cookie jar, which is exactly what switching modes means.
                // The auto-click flag rides along for the same reason: user
                // scripts are registered once, at creation.
                .id("\(model.privateMode)-\(autoPlayClick)")
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
        .confirmationDialog(
            "Close this page?",
            isPresented: $confirmLeavingPrivate,
            titleVisibility: .visible
        ) {
            Button("Close page", role: .destructive) { leavePrivateMode(keepPage: false) }
            Button("Keep it open") { leavePrivateMode(keepPage: true) }
            Button("Stay private", role: .cancel) {}
        } message: {
            Text("Private browsing is turning off, so this page will be recorded in history from now on.")
        }
        .onChange(of: model.currentURL) { url in
            if let url, !editingAddress { addressText = url.absoluteString }
            // No title yet: at this instant `pageTitle` still holds the page we
            // just left, and passing it filed the new site under the old one's
            // name. The entry lands with the host as a placeholder and the
            // onChange below fills it in when the real title arrives.
            if let url { store.recordVisit(url: url, title: "") }
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

    // MARK: private browsing

    private func enterPrivateMode() {
        model.setPrivateMode(true)
        addressText = ""
        // The rebuilt web view starts on its own start page; nothing carries
        // over, which is the point.
    }

    /// `keepPage` reopens the current URL in the persistent store. It cannot be
    /// carried across: the page we are on lives in a data store that is being
    /// thrown away, so keeping it means loading it again on the other side.
    private func leavePrivateMode(keepPage: Bool) {
        let current = model.currentURL?.absoluteString
        model.setPrivateMode(false)
        guard keepPage, let current else { return }
        pendingAddress = current
    }

    // MARK: address bar

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.privateMode ? "eyeglasses" : "magnifyingglass")
                .foregroundStyle(model.privateMode ? Self.privateTint : .secondary)
                .font(.footnote)

            TextField(
                model.privateMode ? "Search privately" : "Search or enter address",
                text: $addressText
            )
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
        .background(
            model.privateMode ? Self.privateTint.opacity(0.18) : PanuraTheme.accentSoft,
            in: Capsule()
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var menu: some View {
        Menu {
            // Page navigation first: these lost their slots when the bottom bar
            // became app-wide, and this is where they live now.
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

            Button {
                if model.privateMode {
                    // Only worth asking about when there is a page to lose.
                    if model.currentURL != nil {
                        confirmLeavingPrivate = true
                    } else {
                        leavePrivateMode(keepPage: false)
                    }
                } else {
                    enterPrivateMode()
                }
            } label: {
                Label(
                    model.privateMode ? "Turn off private browsing" : "Private browsing",
                    systemImage: model.privateMode ? "eyeglasses" : "eyeglasses"
                )
            }

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

    /// The stream the bar speaks for: the same ranking the sheet lists by, so
    /// the one named here is the one Play would have chosen anyway.
    private var primary: ExtractedVideo? { model.orderedVideos.first }

    /// One bar for every count.
    ///
    /// It used to be a capsule that said "3 videos found" and nothing else, and
    /// the common case — take the best stream and play it — cost a tap through
    /// the sheet to reach. Now the top pick's quality and size are pinned beside
    /// the glyph (that is what the choice is made on), its filename follows, the
    /// counts ride as badges, and its actions sit underneath. The row itself
    /// still opens the sheet, which is where probe state, refresh and remove
    /// live.
    @ViewBuilder
    private var foundBar: some View {
        VStack(spacing: 6) {
            if let primary {
                Button { showFoundSheet = true } label: { infoRow(primary) }
                    .buttonStyle(.plain)
                actionRow(primary)
            } else {
                Button { showFoundSheet = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ladybug.fill")
                        Text("Sniffer log (\(model.debugLog.count))").fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.up").font(.footnote)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func infoRow(_ video: ExtractedVideo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "play.rectangle.fill")
                .font(.footnote)
                .foregroundStyle(PanuraTheme.accent)

            // Pinned beside the glyph, never truncated: quality is what the
            // choice is actually made on, so it has to survive a long filename.
            if let tag = video.probeResult?.qualityTag {
                Text(tag)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PanuraTheme.accent)
            }
            if let size = video.probeResult?.fileSize {
                // Deliberately not the quality colour: the two sit side by side
                // and answer different questions.
                Text(size)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            if video.probeState == .pending {
                ProgressView().controlSize(.mini)
            }

            Text(video.fileLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            // The bar counts nothing in words any more, so the badges are what
            // say how many there are.
            countBadge(systemImage: "play.rectangle.fill", count: model.foundVideos.count)
            // Subtitles earn a badge only when there are any; an empty one would
            // be a permanent zero.
            if !model.foundSubtitles.isEmpty {
                countBadge(systemImage: "captions.bubble.fill", count: model.foundSubtitles.count)
            }
            Image(systemName: "chevron.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func countBadge(systemImage: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9))
            Text("\(count)").font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(PanuraTheme.accent, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
    }

    /// The top pick's actions, in the bar whatever the count is — the list
    /// behind the row is for choosing a different stream, not for reaching the
    /// obvious one.
    private func actionRow(_ video: ExtractedVideo) -> some View {
        HStack(spacing: 8) {
            Button {
                playItem = model.playable(video)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PanuraTheme.accent)

            if cast.isConnected {
                Button {
                    cast.cast(model.playable(video))
                } label: {
                    Label("Cast", systemImage: "tv")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if panuraCast.isTVConnected {
                Button {
                    panuraCast.cast(model.playable(video))
                    showPanuraControls = true
                } label: {
                    Label("Panura TV", systemImage: "appletv.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private var foundSheet: some View {
        NavigationStack {
            List {
                ForEach(model.orderedVideos) { video in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(video.title.isEmpty ? video.fileLabel : video.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            probeBadge(video)
                        }
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
                    .swipeActions {
                        Button(role: .destructive) { model.remove(video) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        model.refreshProbes()
                    } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.foundVideos.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showFoundSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// What the probe learned, in the one place there is room to spell it out.
    @ViewBuilder
    private func probeBadge(_ video: ExtractedVideo) -> some View {
        switch video.probeState {
        case .pending:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking").font(.caption2)
            }
            .foregroundStyle(.secondary)
        case .active:
            HStack(spacing: 4) {
                if let tag = video.probeResult?.qualityTag {
                    Text(tag).font(.caption2.weight(.bold)).foregroundStyle(PanuraTheme.accent)
                }
                if let size = video.probeResult?.fileSize {
                    Text(size).font(.caption2).foregroundStyle(.orange)
                }
                if let kind = video.probeResult?.hlsType, video.probeResult?.qualityTag == nil {
                    Text(kind).font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .inactive:
            Text("Dead").font(.caption2.weight(.medium)).foregroundStyle(.red)
        case .skipped:
            Text("Page").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
