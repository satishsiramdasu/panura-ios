import SwiftUI

struct BrowserView: View {
    /// Address handed over from Home. Cleared once loaded so the same entry
    /// isn't replayed on every tab switch.
    @Binding var pendingAddress: String?
    /// The header glyph goes Home, exactly as Android's does.
    var onGoHome: () -> Void = {}
    /// The options panel's Settings cell. Android sends this straight to the
    /// browser section; iOS has one settings screen, so it lands there.
    var onOpenSettings: () -> Void = {}

    @StateObject private var model = BrowserModel()
    @ObservedObject private var store = BrowsingStore.shared
    @ObservedObject private var panuraCast = PanuraCastManager.shared
    @EnvironmentObject private var cast: CastManager
    @State private var playItem: MediaItem?
    @State private var showFoundSheet = false
    @State private var showPanuraControls = false
    @State private var showMenu = false
    @State private var showAddress = false
    @State private var showReport = false
    @State private var toast: String?
    /// Asked when private browsing is switched OFF with a page still open — the
    /// session is live and is about to start being recorded again.
    @State private var confirmLeavingPrivate = false
    @AppStorage("debug_detection") private var debugDetection = false
    /// Only read to rebuild the web view when it changes: user scripts are fixed
    /// at creation, so a toggle in Settings means nothing until a new one exists.
    @AppStorage("auto_play_click") private var autoPlayClick = true

    /// Android's private-browsing violet, not the app accent: the pill has to
    /// read as "private" in any theme, and the accent is what everything else in
    /// the header already wears.
    private static let privateTint = Color(red: 0.78, green: 0.66, blue: 1.0)

    private var pageUsable: Bool {
        guard let url = model.currentURL?.absoluteString else { return false }
        return !url.isEmpty && url != "about:blank"
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header
                progressBar
                WebViewContainer(model: model)
                    // A data store cannot be swapped on a live web view, so
                    // private mode gets a new one. Rebuilding also drops the back
                    // list and the cookie jar, which is exactly what switching
                    // modes means. The auto-click flag rides along for the same
                    // reason: user scripts are registered once, at creation.
                    .id("\(model.privateMode)-\(autoPlayClick)")
            }

            if showMenu { menuPanel }
        }
        .safeAreaInset(edge: .bottom) {
            // With diagnostics on the bar must also open when nothing was
            // detected — that is precisely the case worth inspecting.
            if !model.foundVideos.isEmpty || (debugDetection && !model.debugLog.isEmpty) {
                foundBar
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0) }
        .fullScreenCover(isPresented: $showAddress) {
            AddressScreen(
                currentURL: model.currentURL?.absoluteString ?? "",
                currentTitle: model.pageTitle,
                onNavigate: { text in
                    showAddress = false
                    model.load(text)
                },
                onDismiss: { showAddress = false }
            )
        }
        .sheet(isPresented: $showPanuraControls) { PanuraCastControlView() }
        .sheet(isPresented: $showFoundSheet) { foundSheet }
        .sheet(isPresented: $showReport) {
            ReportIssueSheet(
                pageURL: model.currentURL?.absoluteString,
                source: "browser",
                onSent: { flash("Report sent") }
            )
        }
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
            // No title yet: at this instant `pageTitle` still holds the page we
            // just left, and passing it filed the new site under the old one's
            // name. The entry lands with the host as a placeholder and the
            // onChange below fills it in when the real title arrives.
            if let url { store.recordVisit(url: url, title: "") }
            // A panel left open over a new page describes the wrong thing.
            showMenu = false
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
        model.load(address)
    }

    // MARK: header — app glyph · address pill · cast

    private var header: some View {
        PanuraHeader(onTapGlyph: onGoHome) {
            AddressPill(
                title: model.pageTitle,
                url: model.currentURL?.absoluteString ?? "",
                placeholder: "Search or enter website",
                background: model.privateMode
                    ? Self.privateTint.opacity(0.22)
                    : Color(.secondarySystemBackground),
                onTap: { showAddress = true },
                leading: {
                    // Same slot Android gives it: first cell inside the pill.
                    Button {
                        guard let url = model.currentURL?.absoluteString else { return }
                        if store.isShortcut(url) {
                            store.removeShortcut(url: url)
                        } else {
                            store.addShortcut(
                                url: url,
                                title: model.pageTitle.isEmpty
                                    ? (model.currentURL?.host ?? url)
                                    : model.pageTitle
                            )
                        }
                    } label: {
                        let saved = store.isShortcut(model.currentURL?.absoluteString ?? "")
                        Image(systemName: saved ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundStyle(saved ? PanuraTheme.accent : Color.secondary)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .disabled(!pageUsable)
                    .accessibilityLabel("Add to shortcuts")
                },
                trailing: {
                    // The page menu, in the pill's last cell — the browser has no
                    // bottom bar of its own, so its options hang off here and the
                    // panel drops from this bar. Chevron while open: this is also
                    // the close.
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showMenu.toggle() }
                    } label: {
                        Image(systemName: showMenu ? "chevron.up" : "line.3.horizontal")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(showMenu ? PanuraTheme.accent : Color.secondary)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showMenu ? "Close menu" : "Menu")
                }
            )
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

    // MARK: options panel

    /// Hangs from the header, square on top and rounded where it ends — it is
    /// attached to the bar rather than floating over it.
    ///
    /// The scrim starts BELOW the header: that bar's menu button is the chevron
    /// that closes this, so it has to stay tappable.
    private var menuPanel: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: PanuraHeader<AnyView>.height)
            ZStack(alignment: .top) {
                Color.black.opacity(0.32)
                    .ignoresSafeArea(edges: .bottom)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { showMenu = false } }

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        // Private browsing, and the page navigation that lost its
                        // slots when the bottom bar became app-wide.
                        Button {
                            showMenu = false
                            if model.privateMode {
                                // Only worth asking about when there is a page to lose.
                                if pageUsable { confirmLeavingPrivate = true }
                                else { leavePrivateMode(keepPage: false) }
                            } else {
                                model.setPrivateMode(true)
                            }
                        } label: {
                            Label(
                                model.privateMode ? "Private browsing On" : "Private browsing Off",
                                systemImage: "eyeglasses"
                            )
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(model.privateMode ? Self.privateTint : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        navButton("chevron.left", "Back", enabled: model.canGoBack) {
                            model.goBack()
                        }
                        navButton("arrow.clockwise", "Reload", enabled: true) {
                            model.reload()
                        }
                        navButton("chevron.right", "Forward", enabled: model.canGoForward) {
                            model.goForward()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider().padding(.horizontal, 16)

                    // One row, evenly divided — five cells, as on Android. Its
                    // Downloads cell has no counterpart here (iOS ships no
                    // download feature), so desktop mode takes that seat: with
                    // the browser's native menu gone this is its only home.
                    HStack(alignment: .top, spacing: 0) {
                        if let url = model.currentURL {
                            ShareLink(item: url) {
                                gridCellLabel("square.and.arrow.up", "Share", enabled: true)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { showMenu = false })
                        } else {
                            gridCellLabel("square.and.arrow.up", "Share", enabled: false)
                        }
                        gridCell("trash", "Clear Cache") {
                            model.clearCache()
                            flash("Cache cleared")
                        }
                        gridCell(
                            model.desktopMode ? "iphone" : "desktopcomputer",
                            model.desktopMode ? "Mobile Site" : "Desktop Site"
                        ) {
                            model.toggleDesktopMode()
                        }
                        gridCell("ladybug", "Report Page", enabled: pageUsable) {
                            showReport = true
                        }
                        gridCell("gearshape", "Settings") { onOpenSettings() }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .background(BottomRoundedRectangle(radius: 20).fill(Material.bar))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func navButton(
        _ icon: String,
        _ label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            showMenu = false
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 38, height: 38)
                .background(Circle().fill(enabled ? PanuraTheme.accentSoft : Color.clear))
                .foregroundStyle(enabled ? PanuraTheme.accent : Color.secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        // Disabled rather than hidden, so the three keep their positions.
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func gridCell(
        _ icon: String,
        _ label: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            showMenu = false
            action()
        } label: { gridCellLabel(icon, label, enabled: enabled) }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func gridCellLabel(_ icon: String, _ label: String, enabled: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color(.secondarySystemBackground)))
            Text(label)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
    }

    /// Android answers these with a snackbar; this is the same message in the
    /// same place, without dragging in a toast framework to say two words.
    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 90)
                .transition(.opacity)
        }
    }

    private func flash(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }

    // MARK: private browsing

    /// `keepPage` reopens the current URL in the persistent store. It cannot be
    /// carried across: the page we are on lives in a data store that is being
    /// thrown away, so keeping it means loading it again on the other side.
    private func leavePrivateMode(keepPage: Bool) {
        let current = model.currentURL?.absoluteString
        model.setPrivateMode(false)
        guard keepPage, let current else { return }
        pendingAddress = current
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

/// Rounded at the bottom only — the options panel is attached to the header, so
/// its top edge is the bar's bottom edge.
struct BottomRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: [.bottomLeft, .bottomRight],
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath
        )
    }
}
