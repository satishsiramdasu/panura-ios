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
    /// Private mode lives here, not on the model: Home's pill toggles it too.
    @ObservedObject private var session = BrowserSession.shared
    @EnvironmentObject private var cast: CastManager
    @State private var playItem: MediaItem?
    @State private var showFoundSheet = false
    @State private var showPanuraControls = false
    /// The cast picker, opened by a Cast tap with no TV connected. The video
    /// that asked for it waits here and goes as soon as one is.
    @State private var showCastPicker = false
    @State private var pendingCast: MediaItem?
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
    /// Same reason: content-blocker lists are attached to a configuration, so
    /// turning the ad blocker on or off means a new web view.
    @AppStorage("ad_block") private var adBlock = true

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
                    .id("\(session.privateMode)-\(autoPlayClick)-\(adBlock)")
            }

            if showMenu { menuPanel }
        }
        // spacing 0: the default leaves a gap between the page and the bar, and
        // the app background showing through it is the dark strip along the
        // bar's top edge.
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
        .sheet(isPresented: $showPanuraControls) {
            PanuraCastControlView().presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCastPicker, onDismiss: castPendingIfConnected) {
            NavigationStack { CastDevicesView() }
                .presentationDragIndicator(.visible)
        }
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

    /// A cast that had to wait for a TV. Sending it on dismissal rather than
    /// making the user find the button again is the whole point of remembering
    /// which video asked.
    private func castPendingIfConnected() {
        guard let item = pendingCast else { return }
        pendingCast = nil
        if panuraCast.isTVConnected {
            panuraCast.cast(item)
            showPanuraControls = true
        } else if cast.isConnected {
            cast.cast(item)
        }
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
                background: session.privateMode
                    ? PanuraTheme.incognito.opacity(0.22)
                    : PanuraTheme.surfaceVariant,
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
                            .foregroundStyle(saved ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
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
                            .foregroundStyle(showMenu ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
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
                            if session.privateMode {
                                // Only worth asking about when there is a page to lose.
                                if pageUsable { confirmLeavingPrivate = true }
                                else { leavePrivateMode(keepPage: false) }
                            } else {
                                model.setPrivateMode(true)
                            }
                        } label: {
                            Label(
                                session.privateMode ? "Private browsing On" : "Private browsing Off",
                                systemImage: "eyeglasses"
                            )
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(
                                session.privateMode ? PanuraTheme.incognito : PanuraTheme.onSurfaceVariant
                            )
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
                            model.desktopMode ? "iphone" : "display",
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
                .background(BottomRoundedRectangle(radius: 20).fill(PanuraTheme.surfaceContainer))
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
                .background(Circle().fill(PanuraTheme.surfaceVariant))
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
                .background(PanuraTheme.surfaceContainerHigh, in: Capsule())
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
                        Image(systemName: "ladybug.fill").font(.system(size: 18))
                        Text("Sniffer log (\(model.debugLog.count))")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.up").font(.footnote)
                    }
                    .frame(height: 30)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        // The app bar under this one owns the home-indicator strip. While it is
        // hidden — scrolled away — this bar is the bottom of the screen and has
        // to keep that strip itself, or its buttons sit on the indicator.
        .padding(.bottom, session.barVisible ? 12 : 12 + AppBarRow.bottomInset)
        .background(PanuraTheme.surfaceContainer)
    }

    /// Sized like the thing it is — the reason the page was opened — rather
    /// than a footnote under it. Text a step up from caption, a 44pt row so the
    /// whole thing is a comfortable target, and the actions below at full
    /// height.
    private func infoRow(_ video: ExtractedVideo) -> some View {
        HStack(spacing: 8) {
            // Which hook found this, rather than "a video was found" — the count
            // badges on the right already say that, and how it was found is the
            // one fact about a detection nothing else on the bar carries.
            sourceBadge(video.source)

            // Pinned beside the glyph, never truncated: quality is what the
            // choice is actually made on, so it has to survive a long filename.
            if let tag = video.probeResult?.qualityTag {
                Text(tag)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(PanuraTheme.accent)
            }
            if let size = video.probeResult?.fileSize {
                // Deliberately not the quality colour: the two sit side by side
                // and answer different questions.
                Text(size)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PanuraTheme.tertiary)
            }
            if video.probeState == .pending {
                ProgressView().controlSize(.small)
            }

            Text(video.fileLabel)
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
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
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    /// Text, network or rule, as a small square beside the stream it describes.
    ///
    /// Diagnostic rather than decorative: when a site misbehaves, "did a rule
    /// claim this or did we guess it off the page text" is the first question,
    /// and this answers it without opening Diagnostics. An unknown source falls
    /// back to the plain video glyph rather than drawing a shrug.
    /// `fallback` fills the slot when nothing said how a URL was found — the
    /// bar has one glyph there and cannot leave it blank, while a sheet row can
    /// simply not draw a badge, which is what Android does.
    @ViewBuilder
    private func sourceBadge(_ source: DetectionSource, fallback: Bool = true) -> some View {
        if source == .unknown {
            if fallback {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(PanuraTheme.accent)
            }
        } else {
            Image(systemName: source.icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .accessibilityLabel(source.label)
        }
    }

    private func countBadge(systemImage: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 11))
            Text("\(count)").font(.caption.weight(.bold))
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(PanuraTheme.accent, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(PanuraTheme.onAccent)
    }

    /// The top pick's actions, in the bar whatever the count is — the list
    /// behind the row is for choosing a different stream, not for reaching the
    /// obvious one.
    private func actionRow(_ video: ExtractedVideo) -> some View {
        HStack(spacing: 8) {
            Button {
                playItem = model.playable(video)
            } label: {
                streamActionLabel("Play", icon: "play.fill", filled: true)
            }
            .buttonStyle(.plain)

            // Always present, connected or not — the same concept as Android's:
            // Cast is how you START casting, so hiding it until a TV is already
            // linked meant the button only ever appeared once it was no longer
            // needed. With nothing connected it opens the picker, and the video
            // that asked goes as soon as one is.
            Button {
                castOrConnect(video)
            } label: {
                streamActionLabel(castLabel, filled: false) {
                    CastMark(connected: castConnected).frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Android's pair exactly: a filled primary button and an outlined one, both
    /// 12pt-rounded with 8/10 content padding and a 16pt glyph. Built by hand
    /// rather than with `.borderedProminent`, whose own padding and tinting put
    /// them a good half-row taller than the Android bar.
    private func streamActionLabel(
        _ title: String,
        icon: String,
        filled: Bool
    ) -> some View {
        streamActionLabel(title, filled: filled) {
            Image(systemName: icon).font(.system(size: 16))
        }
    }

    /// The same button with a drawn glyph instead of a symbol name — the cast
    /// mark is not in SF Symbols, so it arrives as a view.
    private func streamActionLabel<Glyph: View>(
        _ title: String,
        filled: Bool,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        HStack(spacing: 6) {
            glyph()
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background {
            if filled {
                RoundedRectangle(cornerRadius: 12).fill(PanuraTheme.accent)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(PanuraTheme.outline, lineWidth: 1)
            }
        }
        .foregroundStyle(filled ? PanuraTheme.onAccent : PanuraTheme.accent)
    }

    private var castConnected: Bool { panuraCast.isTVConnected || cast.isConnected }

    /// "Play on TV" when nothing is linked — the action, not the machinery,
    /// and the same words Android uses. Once a TV is linked the button names
    /// it instead, because by then the question is which screen this goes to.
    private var castLabel: String {
        if panuraCast.isTVConnected { return "Panura TV" }
        if cast.isConnected { return "Chromecast" }
        return "Play on TV"
    }

    /// Panura TV first when both are linked: it plays what this app plays, and
    /// Chromecast is limited to what its receiver accepts.
    private func castOrConnect(_ video: ExtractedVideo) {
        let item = model.playable(video)
        if panuraCast.isTVConnected {
            panuraCast.cast(item)
            showPanuraControls = true
        } else if cast.isConnected {
            cast.cast(item)
        } else {
            pendingCast = item
            showCastPicker = true
        }
    }

    private var foundSheet: some View {
        NavigationStack {
            List {
                ForEach(model.orderedVideos) { video in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            sourceBadge(video.source, fallback: false)
                            Text(video.title.isEmpty ? video.fileLabel : video.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            probeBadge(video)
                        }
                        Text(video.url.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Button {
                                showFoundSheet = false
                                playItem = model.playable(video)
                            } label: {
                                streamActionLabel("Play", icon: "play.fill", filled: true)
                            }
                            .buttonStyle(.plain)

                            Button {
                                showFoundSheet = false
                                castOrConnect(video)
                            } label: {
                                streamActionLabel(castLabel, filled: false) {
                                    CastMark(connected: castConnected)
                                        .frame(width: 18, height: 18)
                                }
                            }
                            .buttonStyle(.plain)
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
                                        entry.verdict.hasPrefix("emitted") ? PanuraTheme.success : PanuraTheme.onSurfaceVariant
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
                    Text(size).font(.caption2).foregroundStyle(PanuraTheme.tertiary)
                }
                if let kind = video.probeResult?.hlsType, video.probeResult?.qualityTag == nil {
                    Text(kind).font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .inactive:
            Text("Dead").font(.caption2.weight(.medium)).foregroundStyle(PanuraTheme.error)
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
