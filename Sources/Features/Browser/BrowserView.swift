import SwiftUI

struct BrowserView: View {
    /// Address handed over from Home. Cleared once loaded so the same entry
    /// isn't replayed on every tab switch.
    @Binding var pendingAddress: String?
    /// The header glyph goes Home, exactly as Android's does.
    var onGoHome: () -> Void = {}
    /// The options panel's Settings cell. Android sends this straight to the
    /// browser section; iOS has one settings screen, so it lands there.
    /// Opens Settings, optionally landing on one screen rather than the root.
    var onOpenSettings: (SettingsScreen?) -> Void = { _ in }

    @StateObject private var model = BrowserModel()
    @ObservedObject private var store = BrowsingStore.shared
    @ObservedObject private var panuraCast = PanuraCastManager.shared
    /// Private mode lives here, not on the model: Home's pill toggles it too.
    @ObservedObject private var session = BrowserSession.shared
    @ObservedObject private var playback = PlaybackSession.shared
    @EnvironmentObject private var cast: CastManager
    @State private var showFoundSheet = false
    /// Which sheet row has its buttons out. The best stream starts open,
    /// because opening the sheet and tapping again to reach Play was two taps
    /// for the thing almost everyone wanted.
    @State private var expandedVideo: ExtractedVideo.ID?
    @State private var showPanuraControls = false
    /// The cast picker, opened by a Cast tap with no TV connected. The video
    /// that asked for it waits here and goes as soon as one is.
    @ObservedObject private var castPicker = CastPicker.shared
    @State private var pendingCast: MediaItem?
    /// A stream found while the TV is already busy, waiting on replace-or-queue.
    @State private var showMenu = false
    @ObservedObject private var siteSettings = SiteSettings.shared
    @State private var showAddress = false
    @State private var showReport = false
    @State private var toast: String?
    /// Asked when private browsing is switched OFF with a page still open — the
    /// session is live and is about to start being recorded again.
    @State private var confirmLeavingPrivate = false
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

            if showMenu {
                PanelScaffold(side: .leading, onDismiss: closeMenu) { panelContent }
            }

        }
        // spacing 0: the default leaves a gap between the page and the bar, and
        // the app background showing through it is the dark strip along the
        // bar's top edge.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.foundVideos.isEmpty {
                foundBar
                    // It arrives at the bottom of a page someone is reading, and
                    // a bar that simply appears there is missed — they carry on
                    // with the site's own player and never learn the app does
                    // anything. So it rises and settles, once.
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(model.foundVideos.count == 1 ? "single" : "many")
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: model.foundVideos.count)
        .overlay(alignment: .bottom) { toastView }
        // The page must go quiet while its video plays in ours, and start
        // again when the player closes — including a close that happens from
        // the Now Playing bar, long after this screen stopped presenting it.
        .onChange(of: playback.isPlayingSomething) { playing in
            model.suspendPageMedia(playing)
        }
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
            CastSessionView()
        }
        // The video that asked for a TV goes as soon as one answers. The panel
        // is drawn at the root, so this only watches it close.
        .onChange(of: castPicker.isShowing) { shown in
            if !shown { castPendingIfConnected() }
        }
        .sheet(isPresented: $showFoundSheet) { foundSheet }
        // The best stream is open on arrival, and re-chosen each time rather
        // than remembered: the page may have found something better since.
        .onChange(of: showFoundSheet) { shown in
            if shown { expandedVideo = model.orderedVideos.first?.id }
        }
        .sheet(isPresented: $showReport) {
            ReportIssueSheet(
                pageURL: model.currentURL?.absoluteString,
                source: "browser",
                onSent: { flash("Report sent") }
            )
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

    /// Hands a detected video to the session, which owns presentation now —
    /// so the player can be dismissed into Picture in Picture and brought back
    /// from the bar without this screen being involved.
    private func play(_ video: ExtractedVideo) {
        PlaybackSession.shared.play(model.playable(video))
    }

    /// A cast that had to wait for a TV. Sending it on dismissal rather than
    /// making the user find the button again is the whole point of remembering
    /// which video asked.
    private func castPendingIfConnected() {
        guard let item = pendingCast else { return }
        pendingCast = nil
        if panuraCast.isTVConnected || cast.isConnected {
            CastFlow.shared.replace(with: [CastFlow.item(for: item)])
            showPanuraControls = true
        }
    }

    /// Load whatever Home handed over, then clear it.
    private func consumePending() {
        #if DEBUG
        ScreenshotMode.prime(model)
        #endif
        guard let address = pendingAddress, !address.isEmpty else { return }
        pendingAddress = nil
        model.load(address)
    }

    // MARK: header — Panura mark · address pill · cast

    /// The Panura mark opens the site panel; the address pill is only an
    /// address again.
    ///
    /// The panel used to hang off a button inside the pill, which made the pill
    /// carry three jobs — where you are, saving the page, and every browser
    /// option — in the width of a phone. The mark is already in this bar, it is
    /// the one control that belongs to the app rather than to the page, and
    /// this is the slot Brave, Chrome and Safari all use for the same panel.
    ///
    /// Going Home by tapping the mark goes with it. That was a second way to
    /// reach a place the app bar already has a seat for; opening what this site
    /// is allowed to do has no other way in.
    private var header: some View {
        PanuraHeader(
            onTapGlyph: { withAnimation(PanelMetrics.motion) { showMenu.toggle() } },
            glyphActive: showMenu,
            glyphMarked: siteLowered,
            glyphLabel: showMenu ? "Close site controls" : "Site controls and browser menu",
            glyphTint: session.privateMode ? PanuraTheme.incognito : nil
        ) {
            AddressPill(
                title: model.pageTitle,
                url: model.currentURL?.absoluteString ?? "",
                placeholder: "Search or enter website",
                // Private browsing colours the whole bar, not just the mark.
                // Dropping this was a mistake: the tint is how the session
                // announces itself, and one small mark is too quiet for a
                // state where nothing is being written down.
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
                    // Back and forward live here now. They were in the options
                    // panel, which made going back a two-tap affair on the one
                    // control people reach for most.
                    HStack(spacing: 0) {
                        pillNav("chevron.left", "Back", enabled: model.canGoBack) {
                            model.goBack()
                        }
                        pillNav("chevron.right", "Forward", enabled: model.canGoForward) {
                            model.goForward()
                        }
                    }
                }
            )
        }
        // Anchored to the bar, not to the page.
        //
        // This hung off the outer stack, and a confirmation dialog now points
        // at the view it was attached to — so a question about private
        // browsing arrived as a bubble growing out of the middle of whatever
        // page was open. It belongs to the bar: the tint that is about to
        // disappear is right here.
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

    /// Something is switched off for the site in the address bar, so the mark
    /// in the header wears a dot.
    ///
    /// A shield was tried in that slot and says it more plainly — a shield can
    /// be struck through. The brand mark wins anyway: it was already in the bar
    /// doing nothing a second control could not do, and one button always in
    /// the same place beats a clearer glyph in a crowded pill.
    /// The television strip is directly under this bar, so this one stops
    /// short of the screen's bottom edge.
    private var castBarShowing: Bool { panuraCast.isCasting || cast.isCasting }

    private var siteLowered: Bool {
        siteSettings.isLowered(host: SiteSettings.key(for: model.currentURL))
    }

    // MARK: options panel

    private func closeMenu() {
        withAnimation(PanelMetrics.motion) { showMenu = false }
    }

    /// The panel that hangs off the Panura mark, pointing back at it.
    ///
    /// It was a `.popover` for one round. That is the right idea — a panel
    /// belonging to a button, with an arrow saying so — and the wrong mechanism
    /// on a phone: the placement is UIKit's, and UIKit drew this one straight
    /// over the address bar it was supposed to hang under. `PanelScaffold` puts
    /// it where it belongs, with the arrow the popover was wanted for.
    ///
    /// No background of its own: the scaffold's is a step lighter than the
    /// header, which is what separates the two without a line between them.
    private var panelContent: some View {
        VStack(spacing: 0) {
            domainRow
            actionRow
            advancedSection
            Divider().padding(.horizontal, 16)
            globalControlsRow
        }
    }

    /// The site the panel is about, given room to be read.
    @ViewBuilder
    private var domainRow: some View {
        let host = SiteSettings.key(for: model.currentURL)
        HStack(spacing: 8) {
            Image(systemName: session.privateMode ? "eyeglasses" : "globe")
                .font(.system(size: 14))
                .foregroundStyle(session.privateMode ? PanuraTheme.incognito : PanuraTheme.onSurfaceVariant)
            Text(host ?? "New tab")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let host, !siteSettings.isDefault(host: host) {
                Button("Reset") {
                    let wasBlocking = siteSettings.value(.adBlock, host: host)
                    siteSettings.reset(host: host)
                    applySiteChange(.adBlock, host: host, was: wasBlocking)
                    model.setDesktopMode(siteSettings.value(.desktop, host: host))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PanuraTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Four actions, straight under the site they act on.
    ///
    /// It was five and included Settings and Desktop Site, both of which now
    /// exist lower down this same panel — one as the row at the foot, the other
    /// as a switch. Private browsing takes a seat here instead of the full-width
    /// row it used to have: it is a thing you turn on, like the rest of them.
    private var actionRow: some View {
        HStack(alignment: .top, spacing: 0) {
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
                gridCellLabel(
                    "eyeglasses",
                    session.privateMode ? "Private On" : "Private",
                    enabled: true,
                    tint: session.privateMode ? PanuraTheme.incognito : nil
                )
            }
            .buttonStyle(.plain)

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
            gridCell("ladybug", "Report Page", enabled: pageUsable) {
                showReport = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    /// What this site is allowed to do, under a heading saying these are the
    /// ones worth thinking about.
    @ViewBuilder
    private var advancedSection: some View {
        if let host = SiteSettings.key(for: model.currentURL) {
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.horizontal, 16)
                Text("ADVANCED OPTIONS")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                ForEach(SiteSettings.Control.allCases) { control in
                    siteToggle(control, host: host)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func siteToggle(_ control: SiteSettings.Control, host: String) -> some View {
        Toggle(isOn: Binding(
            get: { siteSettings.value(control, host: host) },
            set: { value in
                let was = siteSettings.value(control, host: host)
                siteSettings.set(control, host: host, to: value)
                applySiteChange(control, host: host, was: was)
            }
        )) {
            HStack(spacing: 10) {
                Image(systemName: control.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(PanuraTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(control.title).font(.footnote.weight(.medium))
                    Text(control.detail)
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .lineLimit(2)
                }
            }
        }
        .tint(PanuraTheme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// Makes a switch real on the page that is already open.
    ///
    /// Each of these costs a reload: WebKit applies blocking rules as resources
    /// are requested and sends the user agent with the request, so nothing
    /// already fetched changes until it is fetched again.
    private func applySiteChange(_ control: SiteSettings.Control, host: String, was: Bool) {
        let now = siteSettings.value(control, host: host)
        guard now != was else { return }
        switch control {
        case .adBlock: model.applyAdBlock(now)
        case .desktop: model.setDesktopMode(now)
        // Nothing to apply: the scripts keep running and the model simply stops
        // keeping what they find. Clearing makes the page match the switch
        // instead of leaving a list the user just asked not to have.
        case .detection: if now { model.reload() } else { model.clearFindings() }
        }
    }

    /// Everything that is the browser's setting rather than this site's.
    ///
    /// Named as such, exactly as Brave separates its global controls, because
    /// the difference is not cosmetic: the auto-click, inline video and the
    /// long-press block are WebKit user scripts, fixed when the web view is
    /// built, and per-site versions of them would mean rebuilding the browser
    /// on every hop between hosts.
    private var globalControlsRow: some View {
        Button {
            showMenu = false
            onOpenSettings(.browser)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15))
                    .foregroundStyle(PanuraTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browser settings")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Defaults for every site")
                        .font(.caption2)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Back and forward, in the pill's last cell — the slot the options menu
    /// held before it moved to the mark. No Reload beside them: pulling the
    /// page down already does that, and a third button at this width costs more
    /// than it returns.
    private func pillNav(
        _ icon: String,
        _ label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 38)
                .foregroundStyle(enabled ? PanuraTheme.onSurfaceVariant : Color.secondary.opacity(0.3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Disabled rather than hidden, so the two keep their positions.
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

    private func gridCellLabel(
        _ icon: String,
        _ label: String,
        enabled: Bool,
        tint: Color? = nil
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(tint ?? (enabled ? Color.primary : Color.secondary.opacity(0.5)))
                .frame(width: 42, height: 42)
                .background(Circle().fill(
                    tint.map { $0.opacity(0.18) } ?? PanuraTheme.surfaceVariant
                ))
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
            // Two shapes, because one stream and nine are different questions.
            //
            // One: there is nothing to choose, so the bar does the choosing —
            // quality, size, filename and the actions, right there.
            //
            // Several: choosing IS the task, and a bar that picked one of them
            // and hid the rest behind a chevron made the choice look made. It
            // says how many and opens the list, in the app's own colour so it
            // reads as the app speaking rather than part of the page.
            if model.foundVideos.count > 1 {
                Button { showFoundSheet = true } label: { manyRow }
                    .buttonStyle(.plain)
            } else if let primary {
                // Not a button. It used to open the sheet, and the sheet then
                // showed one row saying exactly what is already on this bar —
                // the same filename, the same quality, the same two actions.
                // The only stream there is has nothing to disclose.
                infoRow(primary)
                actionRow(primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // Nothing sits under this any more — the bottom bar is gone — so it is
        // the bottom of the screen and keeps the home-indicator strip itself, or
        // its buttons sit under the indicator. Unless the cast bar is there, in
        // which case that strip is its job and this one sits straight on top of
        // it: two bars with a gap of app background between them read as two
        // unrelated things.
        .padding(.bottom, castBarShowing ? 8 : 10 + AppChrome.bottomInset)
        .background(PanuraTheme.surfaceContainer)
    }

    /// Sized like the thing it is — the reason the page was opened — rather
    /// than a footnote under it. Text a step up from caption, a 44pt row so the
    /// whole thing is a comfortable target, and the actions below at full
    /// height.
    /// One stream in the sheet.
    ///
    /// The filename, not the page title. Every stream here came from the same
    /// page, so repeating that page's name on each row said nothing and cost
    /// two lines apiece — it is the sheet's heading now. What is left is what
    /// tells two streams apart: where it came from, what it is called, and what
    /// the probe made of it.
    ///
    /// Buttons belong to the open row only, as on Android. All of them at once
    /// turned a list of four into a wall of eight buttons.
    @ViewBuilder
    private func foundSheetRow(_ video: ExtractedVideo) -> some View {
        let open = expandedVideo == video.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                var transaction = Transaction()
                transaction.animation = .easeOut(duration: 0.18)
                withTransaction(transaction) {
                    expandedVideo = open ? nil : video.id
                }
            } label: {
                HStack(spacing: 10) {
                    // A glyph, not a picture. Every stream on a page shares the
                    // page's poster — it describes the page, not the variant —
                    // so a column of identical thumbnails told the rows apart
                    // not at all while taking the width that the facts need.
                    // The poster is in the header instead, said once.
                    Image(systemName: "film.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(PanuraTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(
                            PanuraTheme.surfaceVariant,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(video.fileLabel)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // The facts the choice is made on, each one its own
                        // badge: how it was found, how big, how good, and how it
                        // is delivered. They were a run-on caption before, where
                        // the eye has to parse a sentence to compare two rows.
                        streamBadges(video)
                    }

                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                HStack(spacing: 8) {
                    Button {
                        showFoundSheet = false
                        play(video)
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    /// The bar when there is a choice to make.
    private var manyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 17, weight: .semibold))
            Text("\(model.foundVideos.count) videos found")
                .font(.subheadline.weight(.semibold))
            if !model.foundSubtitles.isEmpty {
                Text("·")
                Text("\(model.foundSubtitles.count) subtitles")
                    .font(.footnote)
                    .opacity(0.9)
            }
            Spacer(minLength: 4)
            Text("Choose")
                .font(.footnote.weight(.semibold))
            Image(systemName: "chevron.up").font(.caption.weight(.bold))
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(PanuraTheme.accent, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

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
        }
        // Nothing to disclose and nothing to tap: the chevron went with the
        // button this row used to be, and the row shrank with it.
        .frame(height: 26)
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
    /// Everything known about one stream, as badges.
    ///
    /// Android says it this way and it is the right way: four short facts that
    /// can be compared down a column at a glance, rather than a sentence per
    /// row that has to be read. What is missing is simply absent — a probe that
    /// was skipped says nothing rather than saying "unknown".
    @ViewBuilder
    private func streamBadges(_ video: ExtractedVideo) -> some View {
        HStack(spacing: 5) {
            if video.source != .unknown {
                // The glyph alone. Spelling out "Network request" or "Page
                // source" beside it doubled the width of the busiest badge to
                // explain a distinction nobody acts on — the icon is there to
                // tell two rows apart, not to teach how detection works.
                badge(nil, systemImage: video.source.icon, label: video.source.label)
            }
            if let tag = video.probeResult?.qualityTag {
                badge(tag, tint: PanuraTheme.accent)
            }
            if let size = video.probeResult?.fileSize {
                badge(size, tint: PanuraTheme.tertiary)
            }
            if let kind = deliveryLabel(video) {
                badge(kind)
            }
            switch video.probeState {
            case .pending:
                badge("Checking")
            case .inactive:
                badge("Dead", tint: PanuraTheme.error)
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    /// Adaptive or progressive — the one fact that decides whether a quality
    /// can be chosen at all.
    private func deliveryLabel(_ video: ExtractedVideo) -> String? {
        if let kind = video.probeResult?.hlsType { return kind }
        switch (video.contentType ?? video.url.pathExtension).lowercased() {
        case "hls", "m3u8", "dash", "mpd": return "Adaptive"
        case "mp4", "m4v", "mov": return "Progressive"
        case "webm": return "WebM"
        default: return nil
        }
    }

    private func badge(
        _ text: String?,
        systemImage: String? = nil,
        tint: Color = PanuraTheme.onSurfaceVariant,
        label: String? = nil
    ) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            }
            if let text {
                Text(text).font(.caption2.weight(.medium))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, text == nil ? 5 : 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: Capsule())
        .lineLimit(1)
        // A glyph-only badge still has to say what it means to VoiceOver.
        .accessibilityLabel(label ?? text ?? "")
    }

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
                play(video)
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
        guard panuraCast.isTVConnected || cast.isConnected else {
            pendingCast = item
            CastPicker.shared.open()
            return
        }
        // Something already on the TV is worth a question: a stream found while
        // another is playing is as often the next thing to watch as it is a
        // correction.
        if panuraCast.isCasting || cast.isCasting {
            // Asked on the cast bar, not here: by the time the question is put,
            // the sheet this came from has closed.
            CastFlow.shared.pendingQueue = CastFlow.item(for: item)
        } else {
            CastFlow.shared.replace(with: [CastFlow.item(for: item)])
            showPanuraControls = true
        }
    }

    private var foundSheet: some View {
        List {
            Section {
                sheetHeader
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(model.orderedVideos) { video in
                    foundSheetRow(video)
                        .swipeActions {
                            Button(role: .destructive) { model.remove(video) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .presentationDetents([.medium, .large])
    }

    /// What this page is, as a picture and a name.
    ///
    /// It was a navigation bar with the page title squeezed into one inline
    /// line, a reload button and a Done button. None of the three earned its
    /// place: a sheet is dismissed by pulling it down, the probes refresh
    /// themselves, and a title that has to fit between two buttons cannot say
    /// what an hour-long film is called. The poster does more than all of it.
    private var sheetHeader: some View {
        HStack(spacing: 12) {
            // Beside the title, not above it, and at a fixed size. A poster
            // given the width of the sheet is as tall as the site published it,
            // which on some pages was most of the screen before a single stream
            // was listed — and every page would then have a header of a
            // different height.
            PosterThumb(
                url: model.posterURL, fallback: "film",
                width: 104, height: 60, corner: 10
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(model.pageTitle.isEmpty ? "Detected videos" : model.pageTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(
                    model.foundVideos.count == 1
                        ? "1 video found"
                        : "\(model.foundVideos.count) videos found"
                )
                .font(.caption)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanuraTheme.surfaceVariant)
        )
    }

    /// Resolution, size and kind, in that order, and only what is known.
    ///
    /// Kind comes from the probe when it ran and from the manifest rule or the
    /// URL when it did not, so a row says whether it is adaptive even before
    /// anything has been fetched — which is the one fact available for free and
    /// the one that decides whether seeking will work.
    private func streamMeta(_ video: ExtractedVideo) -> String {
        var parts: [String] = []
        if let tag = video.probeResult?.qualityTag { parts.append(tag) }
        if let size = video.probeResult?.fileSize { parts.append(size) }
        if let kind = video.probeResult?.hlsType {
            parts.append(kind)
        } else {
            switch (video.contentType ?? video.url.pathExtension).lowercased() {
            case "hls", "m3u8": parts.append("Adaptive")
            case "dash", "mpd": parts.append("Adaptive")
            case "mp4", "m4v", "mov": parts.append("Progressive")
            case "webm": parts.append("WebM")
            default: break
            }
        }
        return parts.isEmpty ? video.url.host ?? "Stream" : parts.joined(separator: "  ·  ")
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
