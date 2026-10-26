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
    /// The Save Offline sheet, while it is up.
    @State private var saveOptions: SaveOptions?
    /// What the selected found row turned out to be, fetched when it is opened.
    @State private var rowDetails: [UUID: DirectLinkProbe.Details] = [:]
    /// Whether this page's list has already been opened for the user.
    ///
    /// Once per page: a list that came back every time another stream turned
    /// up would be a sheet that cannot be closed.
    @State private var offeredFoundSheet = false
    @Environment(\.destinationIsActive) private var isActive
    /// Which sheet row has its buttons out. The best stream starts open,
    /// because opening the sheet and tapping again to reach Play was two taps
    /// for the thing almost everyone wanted.
    @State private var expandedVideo: ExtractedVideo.ID?
    /// Whether the open row is the user's choice rather than ours.
    ///
    /// Until they touch a row, the open one is whichever stream is best *now*,
    /// not whichever was best when the sheet rose. The sheet opens the moment a
    /// second stream is sighted, while both are still being probed; a probe
    /// that then drops or outranks the row picked at that instant left the
    /// sheet with no row open, and so no buttons at all.
    @State private var rowChosenByUser = false
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
    /// Which end of the page the toast appears at.
    ///
    /// Beside whatever was pressed: the site panel hangs from the bar at the
    /// top, and the found-video bar is along the bottom. A message about a tap
    /// that appears at the other end of the screen from the tap reads as
    /// something the app decided on its own.
    @State private var toastAtBottom = false
    /// Asked when private browsing is switched OFF with a page still open — the
    /// session is live and is about to start being recorded again.
    /// Only read to rebuild the web view when it changes: user scripts are fixed
    /// at creation, so a toggle in Settings means nothing until a new one exists.
    @AppStorage("auto_play_click") private var autoPlayClick = true
    /// Same reason: content-blocker lists are attached to a configuration, so
    /// turning the ad blocker on or off means a new web view.
    @AppStorage("ad_block") private var adBlock = true
    @Environment(\.screenChrome) private var chrome

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
                    // On the page, inside its own frame, so there is nothing
                    // to measure: the page ends where the found-video bar
                    // begins and where the cast bar begins, and a toast at the
                    // bottom of it lands just above whichever is there.
                    //
                    // It used to hang off the bottom of the whole screen with
                    // 90 points of padding, a number that cleared the bottom
                    // navigation bar - which no longer exists - and did not
                    // clear the found bar, which does.
                    .overlay(alignment: toastAtBottom ? .bottom : .top) { toastView }
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
                    withoutSheetAnimation { showAddress = false }
                    model.load(text)
                },
                onDismiss: { withoutSheetAnimation { showAddress = false } }
            )
        }
        // The video that asked for a TV goes as soon as one answers.
        //
        // **Both triggers, and the connection is the important one.** Only the
        // dismissal was watched, and picking a television does not dismiss
        // anything — the dialog stays up and turns into its connected state,
        // reading "play a video to send it over" while the video that asked
        // for it sat in `pendingCast` doing nothing. It went on the way out,
        // which is why closing the dialog by hand looked like what started
        // playback.
        .onChange(of: castPicker.isShowing) { shown in
            if !shown { castPendingIfConnected() }
        }
        .onChange(of: cast.isConnected) { connected in
            if connected { castPendingIfConnected() }
        }
        .onChange(of: panuraCast.isTVConnected) { connected in
            if connected { castPendingIfConnected() }
        }
        // Only ever over the browser. This layer stays alive behind the other
        // sections, and a sheet raised a beat after you switched away landed on
        // Home or Videos; so it is shown only while this section is the active one.
        .sheet(isPresented: Binding(get: { showFoundSheet && isActive }, set: { showFoundSheet = $0 })) { foundSheet }
        .sheet(item: Binding(get: { isActive ? model.directLink : nil }, set: { model.directLink = $0 })) { offer in
            directLinkSheet(offer)
        }
        // The best stream is open on arrival, and re-chosen each time rather
        // than remembered: the page may have found something better since.
        .onChange(of: showFoundSheet) { shown in
            if shown {
                expandedVideo = nil
                rowChosenByUser = false
                offeredFoundSheet = true
            }
        }
        .onChange(of: model.foundVideos.count) { count in
            // Empty means a new page: its list is a new offer.
            if count == 0 { offeredFoundSheet = false }
            offerFoundSheet()
        }
        // Streams found while another tab was in front are offered on return.
        .onChange(of: isActive) { active in
            // Leaving the browser takes its sheets with it.
            if !active {
                showFoundSheet = false
                model.directLink = nil
                saveOptions = nil
            }
            offerFoundSheet()
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
        .onChange(of: model.posterURL) { poster in
            if let url = model.currentURL {
                store.recordPoster(url: url, poster: poster, alternate: model.posterFallbackURL)
            }
        }
        .onChange(of: model.pageTitle) { title in
            if let url = model.currentURL, !title.isEmpty {
                store.recordVisit(url: url, title: title)
            }
        }
        .onChange(of: pendingAddress) { _ in consumePending() }
        .onAppear { consumePending() }
    }

    /// Opens the sheet by itself, at half height, the first time a page has a
    /// find — once per page, whatever the count. The bar stays underneath for
    /// reopening.
    ///
    /// Never over something else: this layer stays alive behind other tabs,
    /// and a sheet raised from a hidden one lands on whatever is in front.
    private func offerFoundSheet() {
        #if DEBUG
        // Only the shot that is of this sheet; on the browser shot it would
        // cover the page the bar is meant to be seen on.
        if ScreenshotMode.isActive, ScreenshotMode.screen != "found" { return }
        #endif
        guard !model.foundVideos.isEmpty, !offeredFoundSheet, isActive,
              !showFoundSheet, !showAddress, !showReport, !showMenu,
              !castPicker.controlsOpen, !castPicker.isShowing,
              !playback.isPlayingSomething
        else { return }
        showFoundSheet = true
    }

    /// Hands a detected video to the session, which owns presentation now —
    /// so the player can be dismissed into Picture in Picture and brought back
    /// from the bar without this screen being involved.
    private func play(_ video: ExtractedVideo) {
        PlaybackSession.shared.play(model.playable(video))
    }

    /// A cast that had to wait for a TV. Sending it the moment one answers,
    /// rather than making the user find the button again, is the whole point
    /// of remembering which video asked.
    ///
    /// Called from two places — a television connecting, and the dialog
    /// closing — so it has to be safe to call twice. Clearing `pendingCast`
    /// before the connection check is what makes it: a dismissal with nothing
    /// connected is somebody changing their mind, and the second call finds
    /// nothing waiting.
    ///
    /// It closes the dialog itself. The dialog's job was to find a television
    /// and it has found one; leaving it up over the video it just sent would
    /// be asking the same question twice.
    private func castPendingIfConnected() {
        guard let item = pendingCast else { return }
        pendingCast = nil
        guard panuraCast.isTVConnected || cast.isConnected else { return }
        CastPicker.shared.close()
        CastFlow.shared.replace(with: [CastFlow.item(for: item)])
        castPicker.controlsOpen = true
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

    // MARK: header — address pill · private switch

    /// The site's own mark opens the site panel; the address pill is only an
    /// address again.
    ///
    /// The panel used to hang off a button inside the pill, which made the pill
    /// carry three jobs — where you are, saving the page, and every browser
    /// option — in the width of a phone. It moved to the pill's leading cell,
    /// the slot Brave, Chrome and Safari all reserve for whatever the address
    /// is about, and then the artwork in that cell became the site's favicon
    /// rather than the app's mark: this is the one screen where the app is the
    /// least interesting thing present.
    ///
    /// Going Home by tapping the mark went with it. That was a second way to
    /// reach a place the tab strip already has a seat for; opening what this
    /// site is allowed to do has no other way in.
    private var header: some View {
        PanuraHeader(showsGlyph: false) {
            HStack(spacing: 8) {
                addressPill
                privateTile
            }
        }
    }

    private var addressPill: some View {
        pill.overlay(alignment: .leading) { siteTrigger }
    }

    /// The part of the pill that opens the site panel.
    ///
    /// **An overlay, which is the whole point.** A favicon is 30 points and
    /// reads as decoration — a poor button for the only door to what a site is
    /// allowed to do — so the first stretch of the pill beside it answers as
    /// well. Done by widening the cell, that target cost a 28-point gap
    /// between the mark and the title; as an overlay it costs nothing, because
    /// an overlay takes no part in layout. The mark sits where it always sat,
    /// hard against the name of the page.
    ///
    /// It draws nothing and it is inside the pill's own bounds, so there is no
    /// clipping to lose a tap to. Hidden from VoiceOver: `SiteFavicon`
    /// underneath is already the labelled button for this, and two elements
    /// doing one job is worse than a small target.
    private var siteTrigger: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: PanelMetrics.siteTriggerWidth)
            .contentShape(Rectangle())
            .onTapGesture { toggleSitePanel() }
            .accessibilityHidden(true)
    }

    /// The icon for the pill's leading cell: the page's own, with a fallback
    /// that is still the page's own.
    ///
    /// `model.faviconURL` is nil for the whole of every page load —
    /// `didStartProvisionalNavigation` clears it and `FaviconScript` does not
    /// answer until document end. Flipping private browsing rebuilds the web
    /// view and reloads from `lastURL`, so that window is exactly when the
    /// cell fell back to the app's mark, which is why private mode looked like
    /// it loses the favicon. It never did; it was waiting.
    ///
    /// `/favicon.ico` off the page's own origin covers the wait. Every site
    /// has had one since before any of this was standardised, and it is the
    /// same guess `FaviconScript` makes when a page declares no icon. Same
    /// origin, so it tells nobody anything — the rule this cell keeps is that
    /// a favicon must never be fetched from a third-party icon service, which
    /// would hand over every site visited.
    private var siteIcon: URL? {
        if let declared = model.faviconURL { return declared }
        guard let current = model.currentURL,
              let scheme = current.scheme, let host = current.host
        else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    private var pill: some View {
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
                onTap: { withoutSheetAnimation { showAddress = true } },
                // The mark, in the cell every browser reserves for whatever the
                // address is about. It was outside the pill, costing the title
                // 48 points on a phone where the title has about a hundred; in
                // here it does the same job and pays nothing.
                //
                // Back and forward are a pair again as a result. Separating them
                // was the better arrangement when this cell was empty, and there
                // is no arrangement where both ideas fit.
                leading: {
                    // The site's mark, not the app's. This is the cell every
                    // browser uses to say what the page is, and it was saying
                    // what the app is - on the one screen where the app is the
                    // least interesting thing present.
                    //
                    // The behaviour is unchanged: it still opens the site
                    // controls, which have no other way in. Only the artwork
                    // is the page's.
                    //
                    // Its natural 30 points, and no more. A wider cell was
                    // how the target grew, and it bought the target by pushing
                    // the title 28 points right — a hole between the mark and
                    // the name of the page it belongs to, which is the one
                    // pairing in this bar that has to read as one thing.
                    // `siteTrigger` takes the target back without it.
                    SiteFavicon(
                        url: siteIcon,
                        active: showMenu,
                        marked: siteLowered,
                        tint: session.privateMode ? PanuraTheme.incognito : nil,
                        label: showMenu ? "Close site controls" : "Site controls and browser menu",
                        onTap: { toggleSitePanel() }
                    )
                },
                trailing: {
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

    /// The same tile Home has, in the same place, doing the same thing.
    ///
    /// This is the other screen where a session is started, and the one where
    /// it matters most that the state is readable — the switch used to be
    /// reachable only from inside the site panel, two taps in, with nothing on
    /// the bar announcing which mode you were in but a faint tint.
    private var privateTile: some View {
        PrivateSwitchTile(
            on: session.privateMode,
            hasPage: model.currentURL != nil,
            fill: session.privateMode
                ? PanuraTheme.incognito.opacity(0.22)
                : PanuraTheme.surfaceVariant,
            height: 44
        ) { keepPage in
            switchPrivate(keepPage: keepPage)
        }
    }

    /// Flips private browsing whichever way it is currently pointing.
    private func switchPrivate(keepPage: Bool) {
        if session.privateMode { leavePrivateMode(keepPage: keepPage) }
        else { enterPrivateMode(keepPage: keepPage) }
    }

    /// Sets this page aside.
    ///
    /// Not in the header. It lived beside the address for a day and was wrong
    /// there: the header is on every screen and belongs to the app, while
    /// setting a page aside is something you do at the moment a video is found.
    /// So it is where the finding is reported - on the found bar beside Play
    /// and Cast, and in the sheet's header card when several streams mean the
    /// bar has no room for buttons.
    ///
    /// A clock, because YouTube's Watch Later is a clock and this is the same
    /// promise. The bookmark glyph is taken, by bookmarks.
    ///
    /// `boxed` gives it the outline Play and Cast wear, so the three read as
    /// one row rather than two buttons and a loose glyph.
    @ViewBuilder
    private func watchLaterButton(boxed: Bool = false) -> some View {
        let url = model.currentURL?.absoluteString ?? ""
        let saved = store.isWatchLater(url)
        Button {
            if saved {
                store.removeWatchLater(url: url)
            } else {
                // Both pictures, not the winner. The winner is whichever
                // the page ranked first, and on a page that names two the
                // first is sometimes the one that does not resolve — which is
                // exactly why the card beside this button asks twice. Saving
                // only the winner saved the broken one.
                store.addWatchLater(
                    url: url,
                    title: model.pageTitle.isEmpty ? (model.currentURL?.host ?? url) : model.pageTitle,
                    poster: model.posterURL?.absoluteString,
                    posterAlt: model.posterFallbackURL?.absoluteString
                )
            }
        } label: {
            let glyph = Image(systemName: saved ? "clock.fill" : "clock")
                .font(.system(size: 16))
                .foregroundStyle(saved ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)

            if boxed {
                ZStack {
                    // A hidden line of the label the other two buttons carry.
                    // Their height is a glyph and a word inside 10 points of
                    // padding; stating 42 here got within two points of that
                    // and looked it. This takes the height from the same text,
                    // so the three cannot drift apart again.
                    Text(" ")
                        .font(.subheadline.weight(.semibold))
                        .hidden()
                    glyph
                }
                .frame(width: 26)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(PanuraTheme.outline, lineWidth: 1)
                }
                .contentShape(Rectangle())
            } else {
                glyph
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .disabled(!pageUsable)
        .accessibilityLabel(saved ? "Remove from Watch Later" : "Watch later")
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

    /// Opens or closes the site panel. Named because the favicon and the strip
    /// of address bar beside it both do it, and two copies of an animation
    /// curve is how they end up differing.
    private func toggleSitePanel() {
        withAnimation(PanelMetrics.motion) { showMenu.toggle() }
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

    /// Keeps this site, or stops keeping it.
    ///
    /// The label is the state, not the verb: a filled glyph over
    /// "Bookmarked" says this site is kept, the same way the panel's switches
    /// show what they are set to. Naming the action instead ("Bookmark") would
    /// leave a cell that looks identical whether or not the site is already
    /// saved, which is the thing somebody opens this panel to find out.
    @ViewBuilder
    private var bookmarkCell: some View {
        let saved = store.isBookmark(bookmarkKey)
        Button {
            guard let current = model.currentURL,
                  let root = SiteTitle.root(of: current)
            else { return }
            let key = root.absoluteString
            if saved {
                store.removeBookmark(url: key)
                flash("Bookmark removed")
            } else {
                bookmarkSite(root)
                flash("Bookmarked")
            }
            closeMenu()
        } label: {
            gridCellLabel(
                saved ? "bookmark.fill" : "bookmark",
                saved ? "Bookmarked" : "Bookmark",
                enabled: pageUsable,
                tint: saved ? PanuraTheme.accent : nil
            )
        }
        .buttonStyle(.plain)
        .disabled(!pageUsable)
    }

    /// The address a bookmark of this site would be stored under.
    ///
    /// The site, not the page. This button lives in the row that names the
    /// host, and Watch Later is what keeps a particular page — bookmarking an
    /// episode under the episode's own address made the bookmark useless the
    /// next time you wanted the site for anything else.
    private var bookmarkKey: String {
        model.currentURL.flatMap(SiteTitle.root(of:))?.absoluteString ?? ""
    }

    /// Saves at once, then corrects the name.
    ///
    /// The title has to come from the site's own front page, and that is a
    /// network round trip — far too long to hold a button press. So the
    /// bookmark is written immediately under the best name already known (the
    /// host, or the page title when you are standing on the front page), and
    /// the fetched one replaces it when it arrives. If the fetch fails nothing
    /// happens and the host remains, which is what it would have been anyway.
    private func bookmarkSite(_ root: URL) {
        let key = root.absoluteString
        let host = root.host ?? key
        let onRoot = (model.currentURL?.path ?? "/").isEmpty
            || model.currentURL?.path == "/"
        let provisional = onRoot && !model.pageTitle.isEmpty ? model.pageTitle : host
        store.addBookmark(url: key, title: provisional)

        Task {
            guard let fetched = await SiteTitle.fetch(root: root),
                  fetched != provisional,
                  store.isBookmark(key)
            else { return }
            store.updateBookmark(original: key, title: fetched, url: key)
        }
    }

    /// Four actions, straight under the site they act on.
    ///
    /// It was five and included Settings and Desktop Site, both of which now
    /// exist lower down this same panel — one as the row at the foot, the other
    /// as a switch.
    ///
    /// Private browsing is no longer among them. It has a labelled switch on
    /// the bar itself now, beside the address, where it is readable without
    /// opening anything — and a mode you can be in without noticing has no
    /// business being two taps deep. Bookmark takes the vacated seat: it was a
    /// 15-point glyph in the corner of the row above, the smallest target on
    /// the panel, for the one action here that most people actually came for.
    private var actionRow: some View {
        HStack(alignment: .top, spacing: 0) {
            bookmarkCell

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
                .frame(width: AppChrome.pillNavWidth, height: 38)
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
                .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                .padding(toastAtBottom ? .bottom : .top, 12)
                .transition(.opacity)
        }
    }

    /// `fromBottom` for anything pressed on the found-video bar; the default
    /// suits the site panel and the bar at the top.
    private func flash(_ message: String, fromBottom: Bool = false) {
        toastAtBottom = fromBottom
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
    /// Both said here rather than at the buttons, because each happens from
    /// two places: the button when there is no page to lose, and the dialog
    /// when there is.
    ///
    /// Nothing re-navigates. The session keeps or clears `lastURL` and the
    /// rebuilt web view loads whichever it finds, so "keep" and "close" are the
    /// same code path with one flag.
    private func leavePrivateMode(keepPage: Bool) {
        model.setPrivateMode(false, keepingPage: keepPage)
        flash("Private browsing off")
    }

    private func enterPrivateMode(keepPage: Bool) {
        model.setPrivateMode(true, keepingPage: keepPage)
        flash("Private browsing on")
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
    /// One shape for every count, as on Android: how many were found, and a
    /// tap opens the sheet, where the choosing and the buttons are. The sheet
    /// opens by itself on detection now, so a separate single-stream bar with
    /// its own Play and Cast was a second thing to learn for nothing.
    @ViewBuilder
    private var foundBar: some View {
        Button { showFoundSheet = true } label: { manyRow }
            .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // Nothing sits under this any more — the bottom bar is gone — so it is
        // the bottom of the screen and keeps the home-indicator strip itself, or
        // its buttons sit under the indicator. Unless the cast bar is there, in
        // which case that strip is its job and this one sits straight on top of
        // it: two bars with a gap of app background between them read as two
        // unrelated things.
        // With the banner under it, the banner is the edge: even padding, so
        // the row sits centred in its strip.
        .padding(.bottom, castBarShowing || AdPolicy.allowsBanner ? 8 : 10 + AppChrome.bottomInset)
        .background(chrome)
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
    /// The row with its buttons out: the user's pick while it still exists,
    /// otherwise the best stream there is.
    private var openRow: ExtractedVideo.ID? {
        let videos = model.orderedVideos
        if rowChosenByUser {
            guard let expandedVideo else { return nil }
            if videos.contains(where: { $0.id == expandedVideo }) { return expandedVideo }
        }
        return videos.first?.id
    }

    @ViewBuilder
    private func foundSheetRow(_ video: ExtractedVideo) -> some View {
        let open = openRow == video.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                var transaction = Transaction()
                transaction.animation = .easeOut(duration: 0.18)
                withTransaction(transaction) {
                    rowChosenByUser = true
                    expandedVideo = open ? nil : video.id
                }
            } label: {
                HStack(spacing: 10) {
                    // A glyph, not a picture. Every stream on a page shares the
                    // page's poster — it describes the page, not the variant —
                    // so a column of identical thumbnails told the rows apart
                    // not at all while taking the width that the facts need.
                    // The poster is in the header instead, said once.
                    Image(systemName: "film")
                        .font(.system(size: 14))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .frame(width: 34, height: 34)
                        .background(
                            PanuraTheme.surfaceContainerHigh,
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
                // Looks the file over once the row is open; the answer lands in its badges.
                Color.clear.frame(height: 0).task(id: video.id) { await loadDetails(video) }
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

                    Button { askToSave(video) } label: {
                        streamActionLabel("Save", icon: "arrow.down.to.line", filled: false)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    private var foundCountText: String {
        model.foundVideos.count == 1 ? "1 video found" : "\(model.foundVideos.count) videos found"
    }

    /// Running time and size, on their own line under the badges. Size is a
    /// range for an adaptive stream — each end of its bitrate ladder.
    private func lengthAndSize(_ video: ExtractedVideo) -> String? {
        let parts = [video.probeResult?.duration, video.probeResult?.fileSize].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// The bar, whatever the count.
    private var manyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 17, weight: .semibold))
            Text(foundCountText)
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
            // Everything about the file in this one row: how good, how long,
            // how big, how it is delivered. What the probe read comes first;
            // what looking at the opened row added fills the gaps.
            let looked = rowDetails[video.id]
            if let tag = video.probeResult?.qualityTag ?? looked?.resolution.flatMap(Self.heightTag) {
                badge(tag, tint: PanuraTheme.accent)
            }
            if let length = video.probeResult?.duration ?? looked?.duration {
                badge(length, systemImage: "clock")
            }
            if let size = video.probeResult?.fileSize ?? looked?.size {
                badge(size, systemImage: "externaldrive")
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

    /// "1920×1080" → "1080p", the number streams are picked by.
    private static func heightTag(_ resolution: String) -> String? {
        let parts = resolution.split(whereSeparator: { $0 == "×" || $0 == "x" })
        guard parts.count == 2, let h = Int(parts[1]) else { return nil }
        return "\(h)p"
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

            // No label. Play and Cast are what the bar is for and have earned
            // their words; this one is a third option on a row that is already
            // two buttons wide on a 375pt phone.
            watchLaterButton(boxed: true)
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
        // Only Play is in colour. The others are tonal — a grey fill, an accent
        // glyph and a plain label — so the one obvious choice stays obvious.
        HStack(spacing: 6) {
            glyph()
                .foregroundStyle(filled ? PanuraTheme.onAccent : PanuraTheme.accent)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                .foregroundStyle(filled ? PanuraTheme.onAccent : PanuraTheme.onSurface)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            filled ? PanuraTheme.accent : PanuraTheme.surfaceContainerHighest,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }


    // MARK: a tapped link to a video file

    /// The dialog for a link somebody tapped that points at a video file: what
    /// the file is, in the words a person would use, and Play / Cast / Save.
    /// No address anywhere — it is long, it says nothing, and the name carries
    /// the point.
    private func directLinkSheet(_ offer: BrowserModel.DirectLinkOffer) -> some View {
        let video = offer.video
        let name = (video.fileLabel.removingPercentEncoding ?? video.fileLabel)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 20))
                    .foregroundStyle(PanuraTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    directLinkSubtitle(offer)
                }
                Spacer(minLength: 0)
            }

            directLinkFacts(offer)

            if case .gone = offer.state {
                Button { model.directLink = nil } label: {
                    Text("Close")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PanuraTheme.onSurface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(PanuraTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    Button {
                        model.directLink = nil
                        play(video)
                    } label: {
                        streamActionLabel("Play", icon: "play.fill", filled: true)
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.directLink = nil
                        castOrConnect(video)
                    } label: {
                        streamActionLabel(castLabel, filled: false) {
                            CastMark(connected: castConnected)
                                .frame(width: 18, height: 18)
                        }
                    }
                    .buttonStyle(.plain)

                    Button { askToSave(video) } label: {
                        streamActionLabel("Save", icon: "arrow.down.to.line", filled: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        // No background of our own: the system sheet material, as the found sheet.
        .presentationDetents([.height(300), .medium])
        .presentationDragIndicator(.visible)
        // Save opens its own sheet; it has to be presented from here, because the
        // found sheet that normally hosts it is not on screen.
        .sheet(item: $saveOptions) { options in
            SaveOfflineSheet(
                options: options,
                onConfirm: { title, variant, audio, subtitle in
                    model.directLink = nil
                    confirm(options, title: title, variant: variant, audio: audio, subtitle: subtitle)
                },
                onCancel: { saveOptions = nil }
            )
        }
    }

    @ViewBuilder
    private func directLinkSubtitle(_ offer: BrowserModel.DirectLinkOffer) -> some View {
        switch offer.state {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking the link…")
            }
            .font(.footnote)
            .foregroundStyle(PanuraTheme.onSurfaceVariant)
        case .ready:
            // The grid below has its type; nothing to say twice.
            EmptyView()
        case .gone:
            Text("No longer available")
                .font(.footnote.weight(.medium))
                .foregroundStyle(PanuraTheme.error)
        }
    }


    /// The video-link dialog's facts: four cells, two by two — what it is,
    /// how big, how long, how sharp — each a small label over its value. Only
    /// the ones the check found; a missing fact leaves its cell out, not blank.
    @ViewBuilder
    private func factsBlock(_ d: DirectLinkProbe.Details) -> some View {
        let cells: [(String, String)] = [
            ("Type", d.kind),
            ("Size", d.size ?? ""),
            ("Length", d.duration ?? ""),
            ("Picture", d.resolution ?? ""),
        ].filter { !$0.1.isEmpty }
        if !cells.isEmpty {
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading, spacing: 14
            ) {
                ForEach(cells.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cells[i].0)
                            .font(.caption)
                            .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        Text(cells[i].1)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanuraTheme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }



    /// Only for the row that was opened, and only for a plain file. A rule-matched
    /// stream is never read: those hosts hand out single-use tokens, and a look
    /// that spends one leaves the player with a 410. A playlist has been read
    /// already, by the probe that made its row.
    private func loadDetails(_ video: ExtractedVideo) async {
        guard rowDetails[video.id] == nil, !video.ruleMatched,
              !isHLS(video), StreamProbe.isDirectMedia(video.url)
        else { return }
        if case .video(let details) = await DirectLinkProbe.check(url: video.url, headers: video.headers) {
            rowDetails[video.id] = details
        }
    }
    /// Size, length, picture size and whether it can be skipped through — only
    /// the ones the check found out.
    @ViewBuilder
    private func directLinkFacts(_ offer: BrowserModel.DirectLinkOffer) -> some View {
        if case .ready(let d) = offer.state { factsBlock(d) }
    }
    // MARK: saving
    private func isHLS(_ video: ExtractedVideo) -> Bool {
        if video.probeResult?.hlsType != nil { return true }
        if ["hls", "m3u8"].contains((video.contentType ?? "").lowercased()) { return true }
        return video.url.absoluteString.lowercased().contains(".m3u8")
    }

    /// Save was tapped. A plain file, or a stream with nothing to choose from,
    /// saves at once; a master with several rungs, other audio or subtitles
    /// opens the Save Offline sheet (Android's `HlsSaveDialog`).
    private func askToSave(_ video: ExtractedVideo) {
        guard isHLS(video) else { save(video, url: video.url); return }
        let item = model.playable(video)
        let title = model.pageTitle.isEmpty ? video.fileLabel : model.pageTitle
        Task {
            guard let (status, text) = await Self.fetchText(video.url, headers: item.headers),
                  (200..<300).contains(status), text.contains("#EXT-X-STREAM-INF")
            else { save(video, url: video.url); return }
            // The running time only feeds the size shown on each quality, so it
            // is fetched only when there is something to show it on.
            var seconds = 0.0
            if let top = StreamProbe.variants(in: text, base: video.url).max(by: { $0.bps < $1.bps }),
               let (_, media) = await Self.fetchText(top.url, headers: item.headers) {
                seconds = StreamProbe.playlistSeconds(media) ?? 0
            }
            let options = SaveOptions.parse(
                master: text, base: video.url, video: video, title: title, seconds: seconds
            )
            guard !options.variants.isEmpty else { save(video, url: video.url); return }
            if options.needsSheet {
                saveOptions = options
            } else {
                save(video, url: options.variants[0].url, resolution: options.variants[0].resolution)
            }
        }
    }

    private func confirm(_ options: SaveOptions, title: String, variant: Int, audio: Int?, subtitle: Int?) {
        let chosen = options.variants[variant]
        saveOptions = nil
        save(
            options.video, url: chosen.url, title: title,
            resolution: chosen.resolution.isEmpty ? nil : chosen.resolution,
            // Audio only counts when the rung keeps it in a playlist of its own.
            audio: chosen.hasAudioGroup ? audio.map { options.audio[$0] } : nil,
            subtitle: subtitle.map { options.subtitles[$0] }
        )
    }

    private func save(
        _ video: ExtractedVideo, url: URL, title: String? = nil, resolution: String? = nil,
        audio: SaveOptions.Track? = nil, subtitle: SaveOptions.Track? = nil
    ) {
        let item = model.playable(video)
        // Saved from the video-link dialog, if that is where this began: it has done
        // its job, and the ad below waits for it to be gone.
        model.directLink = nil
        let typed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        DownloadStore.shared.enqueue(
            title: typed.isEmpty ? (model.pageTitle.isEmpty ? video.fileLabel : model.pageTitle) : typed,
            pageURL: model.currentURL?.absoluteString ?? video.url.absoluteString,
            streamURL: url,
            headers: item.headers,
            poster: model.posterURL?.absoluteString,
            posterAlt: model.posterFallbackURL?.absoluteString,
            isHLS: isHLS(video),
            resolution: resolution,
            audio: audio,
            subtitle: subtitle
        )
        // After it was enqueued, never before (docs/ads.md §1), and not while
        // the Save Offline sheet is still leaving: an ad presented from a sheet
        // that is dismissing is dismissed with it, which looked like the ad
        // closing itself. Whatever the ad does, the user ends up looking at the
        // download: the list of found videos closes and Downloads opens over the
        // page, so there is no doubt it started and no list left to wander into.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            AdManager.shared.showInterstitial(.download) {
                showFoundSheet = false
                // The found sheet has to finish leaving before another can come up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    DownloadStore.shared.presentRequest = true
                }
            }
        }
    }

    /// RESOLUTION per variant URL, for the save dialog's labels.
    private static func resolutions(in master: String, base: URL) -> [URL: String] {
        var out: [URL: String] = [:]
        var pending: String?
        for raw in master.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("#EXT-X-STREAM-INF") {
                pending = line.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression)
                    .map { String(line[$0]).split(separator: "x").last.map { "\($0)p" } ?? "" }
            } else if let res = pending, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL { out[url] = res }
                pending = nil
            }
        }
        return out
    }

    private static func fetchText(_ url: URL, headers: [String: String]) async -> (Int, String)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (name, value) in headers where !value.isEmpty { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, String(decoding: data.prefix(2_000_000), as: UTF8.self))
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
            castPicker.controlsOpen = true
        }
    }

    /// Always a half sheet first — the poster card and the best stream's
    /// actions in view — that grows as it is dragged or its list scrolled.
    /// Neutral throughout: flat grey cards, and only Play in colour.
    private var foundSheet: some View {
        ScrollView {
            VStack(spacing: 10) {
                sheetHeader
                countDivider
                ForEach(model.orderedVideos) { video in
                    foundSheetRow(video)
                        .padding(12)
                        .background(
                            PanuraTheme.surfaceVariant,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .contextMenu {
                            Button(role: .destructive) { model.remove(video) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            // Clear of the grabber.
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        // No background of our own. The system sheet material is what gives the
        // half sheet its inset, translucent look and the darkening as it is
        // dragged up; painting a colour behind the list replaced it with a
        // flat, full-width black.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $saveOptions) { options in
            SaveOfflineSheet(
                options: options,
                onConfirm: { title, variant, audio, subtitle in
                    confirm(options, title: title, variant: variant, audio: audio, subtitle: subtitle)
                },
                onCancel: { saveOptions = nil }
            )
        }
        // The browser's copy is under this sheet, where nobody can see it, so
        // the sheet shows the same message itself.
        .overlay(alignment: .top) { toastView }
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
            //
            // 142x80 is what the Videos list gives a row, so a video found on a
            // page and a video already on the phone are drawn at one size. The
            // shape no longer decides what is cropped: a portrait poster fits
            // inside it over a blur of itself.
            PosterThumb(
                url: model.posterURL, alternate: model.posterFallbackURL,
                fallback: "film", width: 120, height: 68, corner: 8
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(model.pageTitle.isEmpty ? "Detected videos" : model.pageTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                // Under the title: it is about the page, not about any one of
                // the streams below. The count went to the divider.
                watchLaterPill
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PanuraTheme.surfaceVariant)
        )
    }

    /// "3 videos found", centred between two hairlines, heading the list.
    private var countDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(PanuraTheme.outline.opacity(0.5)).frame(height: 1)
            Text(foundCountText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .fixedSize()
            Rectangle().fill(PanuraTheme.outline.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    /// Watch Later as a short grey pill under the page title; tonal accent
    /// once the page is kept.
    private var watchLaterPill: some View {
        let url = model.currentURL?.absoluteString ?? ""
        let saved = store.isWatchLater(url)
        return Button {
            if saved {
                store.removeWatchLater(url: url)
            } else {
                store.addWatchLater(
                    url: url,
                    title: model.pageTitle.isEmpty ? (model.currentURL?.host ?? url) : model.pageTitle,
                    poster: model.posterURL?.absoluteString,
                    posterAlt: model.posterFallbackURL?.absoluteString
                )
            }
        } label: {
            // Said as an act, and the tick says it is done: "Add to Watch Later"
            // becomes "Added to Watch Later" with a check.
            Label(saved ? "Added to Watch Later" : "Add to Watch Later", systemImage: saved ? "checkmark" : "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(saved ? PanuraTheme.accent : PanuraTheme.onSurface)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    saved ? PanuraTheme.accentSoft : PanuraTheme.surfaceContainerHighest,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!pageUsable)
        .accessibilityLabel(saved ? "Remove from Watch Later" : "Watch later")
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
