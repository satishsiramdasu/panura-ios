import UIKit
import SwiftUI

/// The app's shell: every destination stacked, one bar under them, and the
/// sections grid hanging above that bar.
///
/// Mirrors Android's `HomeScreen` after the nav rebuild — Home, Web and Videos
/// in the bar, Network Stream and Settings behind the grid. It is deliberately
/// NOT a `TabView`: five co-equal tabs said all five were places you switch
/// between, when only three are, and a `UITabBar` cannot draw the one-label
/// pill the bar now uses to say where you are.
///
/// Every destination stays composed and is hidden by opacity rather than being
/// rebuilt. The browser owns a live `WKWebView`, a page mid-load and a set of
/// detections; taking a trip to Home must not cost any of that.
///
/// iOS ships no download feature at all — saving streamed content is the
/// clearest App Review 5.2.3 problem in this app, and a flag-gated feature still
/// ships the code — so the bar has no Downloads seat to trade Videos for, as
/// Android's does inside the browser.
struct RootTabView: View {
    @State private var selection: AppDestination = {
        #if DEBUG
        // The screenshot run opens each screen by launching into it rather than
        // by tapping its way there — see ScreenshotMode.screen.
        if ScreenshotMode.isActive {
            switch ScreenshotMode.screen {
            case "web": return .web
            case "videos", "player": return .videos
            case "stream": return .stream
            // Settings is a sheet now; the screenshot run opens it from Home
            // in `.task` below rather than by landing on it.
            case "settings": return .home
            default: return .home
            }
        }
        #endif
        return .home
    }()
    /// Address typed on Home, waiting for the Browser to pick it up. The browser
    /// owns its WebView across switches, so the hand-off has to be state here
    /// rather than a fresh `BrowserView(url:)`.
    @State private var pendingAddress: String?
    @ObservedObject private var session = BrowserSession.shared
    @ObservedObject private var playback = PlaybackSession.shared
    @ObservedObject private var panuraCast = PanuraCastManager.shared
    @ObservedObject private var chromecast = CastManager.shared
    /// The cast remote, opened from the bar.
    @State private var showCastControls = false
    /// The report sheet, reachable from the menu rather than only the browser.
    @State private var showReport = false
    @State private var showFAQ = false
    @ObservedObject private var castFlow = CastFlow.shared
    @ObservedObject private var castPicker = CastPicker.shared
    /// Which Settings screen to land on, when something asked for one.
    @State private var settingsDeepLink: SettingsScreen?
    /// Settings is a sheet, not a destination. It is somewhere you go *from*
    /// wherever you are and come back out of, which is what a sheet is; as a
    /// destination it also had to carry the app's header, and every screen
    /// pushed inside it then arrived wearing a different one.
    @State private var showSettings = false

    @ObservedObject private var drawer = DrawerState.shared

    /// Push the drawer back where it came from.
    ///
    /// The way it opened, reversed - which is how a drawer is expected to close,
    /// and a tap on the sliver of app showing beside it was the only way to do
    /// it. 24 points before it counts, so it never fires on the little sideways
    /// drift of a finger that meant to press a row.
    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard value.translation.width < -40 else { return }
                dismissDrawerIfOverlay()
            }
    }

    /// Regular width means an iPad with room to spare - never a phone, and not
    /// an iPad in Split View or Slide Over, which report compact and so get the
    /// phone's drawer back. That is right for both: a sidebar on a half-width
    /// iPad window would leave the app less room than a phone has.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPad only, and the idiom check is not redundant.
    ///
    /// A large iPhone reports `.regular` width in landscape. Keyed on the size
    /// class alone, rotating the phone swapped `pushLayout` for `sidebarLayout`
    /// - a different view tree, so every child was rebuilt, the web view with
    /// them, and the browser reloaded its start page. Turning the phone sideways
    /// threw away the page you were reading.
    private var usesSidebar: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }
    /// The sidebar starts open on an iPad, but only the first time. Reopening
    /// it on every rotation would overrule someone who had just closed it.
    @State private var didOpenSidebar = false

    /// Closing the drawer is a phone idea. On an iPad the sidebar is furniture:
    /// pressing a row in it is not a reason to take it away.
    private func dismissDrawerIfOverlay() {
        guard !usesSidebar else { return }
        drawer.close()
    }

    /// The phone: the app slides off the drawer rather than the drawer over the
    /// app, which is what keeps the way out under the thumb that opened it.
    private var pushLayout: some View {
        ZStack(alignment: .leading) {
            // Underneath, revealed by the app moving off it. A drawer that
            // slides over the app hides how to get back; one the app slides off
            // keeps the way out under the thumb that opened it.
            if drawer.isOpen {
                AppDrawerPanel(
                    destinations: drawerDestinations,
                    actions: drawerActions,
                    onAbout: {
                        dismissDrawerIfOverlay()
                        settingsDeepLink = .about
                        showSettings = true
                    }
                )
                .frame(width: DrawerState.width)
                .transition(.move(edge: .leading))
                // Alongside the rows rather than instead of them: a drag that
                // starts on a row still closes the drawer, and a tap on the same
                // row still opens what it names.
                .simultaneousGesture(closeDrag)
            }

            shell
                .offset(x: drawer.isOpen ? DrawerState.width : 0)
                // Rounded and lifted only while it is aside, so the app reads as
                // a card resting on the drawer rather than a screen cut in half.
                .clipShape(
                    RoundedRectangle(cornerRadius: drawer.isOpen ? 22 : 0, style: .continuous)
                )
                .shadow(color: .black.opacity(drawer.isOpen ? 0.45 : 0), radius: 22, x: -6)
                // Nothing on a screen that is half off the screen should be
                // operable. This used to be an overlay carrying the tap that
                // closes the drawer, and the overlay was hit-tested against the
                // shell's *unoffset* frame — the whole screen — so it sat on top
                // of the drawer and swallowed every tap meant for a row. The
                // drawer looked dead. The tap-to-close is its own view below,
                // inset past the drawer, where it can only cover the app.
                // `disabled` would not be enough: it stops SwiftUI controls
                // and says nothing to a UIKit view, so the web page underneath
                // would still scroll under a finger.
                .allowsHitTesting(!drawer.isOpen)

            if drawer.isOpen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { drawer.close() }
                    .gesture(closeDrag)
                    .padding(.leading, DrawerState.width)
                    .ignoresSafeArea()
            }
        }
    }

    /// The iPad: the drawer is furniture, not an interruption.
    ///
    /// It takes its width out of the layout instead of sliding the app off the
    /// screen, so both are usable at once - which is the whole difference. The
    /// phone's drawer has to be dismissed before anything else can be touched,
    /// because it is covering the app. This one is beside it, so there is
    /// nothing to dismiss: no scrim, no tap-to-close, no swipe, and no row that
    /// puts it away when pressed.
    private var sidebarLayout: some View {
        HStack(spacing: 0) {
            if drawer.isOpen {
                AppDrawerPanel(
                    destinations: drawerDestinations,
                    actions: drawerActions,
                    onAbout: {
                        settingsDeepLink = .about
                        showSettings = true
                    }
                )
                .frame(width: DrawerState.width)
                .transition(.move(edge: .leading))
                Divider().overlay(PanuraTheme.surfaceVariant)
            }
            shell
        }
    }

    var body: some View {
        Group {
            if usesSidebar { sidebarLayout } else { pushLayout }
        }
        .onAppear {
            guard usesSidebar, !didOpenSidebar else { return }
            didOpenSidebar = true
            drawer.isOpen = true
        }
        .background(PanuraTheme.surfaceContainer.ignoresSafeArea())
        // One bottom edge for everything in the stack — the screen's, not the
        // safe area's. The cast bar's own ground has to reach the bottom of the
        // display, and it is the last thing on the screen now that the bottom
        // bar is gone.
        .ignoresSafeArea(.container, edges: .bottom)
        // The one player presenter in the app. It used to be five — every
        // screen that could start a video owned its own cover — and none of
        // them could reopen it once the user had walked away, which is exactly
        // what the bar has to do.
        .fullScreenCover(item: $playback.presented) { playing in
            PlayerScreen(item: playing.item, playlist: playing.playlist)
        }
        // One screen for the whole of casting — getting the video ready, the
        // conversion some TVs need, the hand-over, and then the controls. It
        // used to open `PanuraCastControlView` whichever path was in use, so a
        // Chromecast showed a screen wired to a receiver it was not talking to.
        .sheet(isPresented: $showCastControls) { CastSessionView() }
        .sheet(isPresented: $showReport) {
            ReportIssueSheet(pageURL: nil, source: "menu")
        }
        .sheet(isPresented: $showFAQ) { FAQView() }
        .sheet(isPresented: $showSettings) {
            SettingsView(deepLink: $settingsDeepLink)
        }
        .task {
            #if DEBUG
            if ScreenshotMode.isActive, ScreenshotMode.screen == "settings" {
                showSettings = true
            }
            #endif
        }
        // Starting a cast anywhere in the app raises it, so the wait is never
        // silent — a Dolby Vision clip can take minutes to convert, and without
        // this the phone simply looked like it had stopped responding.
        .onChange(of: castFlow.showing) { showing in
            if showing { showCastControls = true }
        }
        // The cast panel cannot present the remote itself — it is closing as it
        // asks — so it asks here, where the sheet outlives it.
        .onChange(of: castPicker.showControls) { wants in
            guard wants else { return }
            castPicker.showControls = false
            showCastControls = true
        }
        .onChange(of: showCastControls) { showing in
            // Dismissing the screen clears a finished attempt, but never stops
            // a conversion — Cancel is what does that, and it is on the screen.
            if !showing { castFlow.settle() }
        }
        // Nothing in release builds — see the modifier below.
        .screenshotPlayer()
    }

    /// Everything that is not the drawer: the destination you are on, and the
    /// strip naming the television when there is one.
    private var shell: some View {
        ZStack {
            content
            // Above every screen, because the mark that opens it is in every
            // header and the panel has to cover what it is about.
            CastPanelOverlay()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            destinations

            // Only a television. Picture in Picture had a bar here too, and it
            // was redundant every single time it appeared: `minimized` is set
            // by exactly one thing, the PiP hand-off, so the bar could never be
            // on screen without iOS already floating the video above it — with
            // pause, close and restore on the window itself, closer to hand
            // than a strip at the bottom. Casting is the opposite. Nothing on
            // the phone shows it at all, which is what earns a permanent strip.
            if isCasting {
                castBar
                    // Replace what is on the TV, or line this up behind it —
                    // asked on the bar, which is what the question is about. It
                    // used to hang off the browser's own view, so dismissing the
                    // found-video sheet was followed by a dialog growing out of
                    // the middle of a web page that knows nothing of any
                    // television.
                    .confirmationDialog(
                        "Something is already on the TV",
                        isPresented: Binding(
                            get: { castFlow.pendingQueue != nil },
                            set: { if !$0 { castFlow.pendingQueue = nil } }
                        ),
                        titleVisibility: .visible
                    ) {
                        Button("Play this instead") {
                            if let item = castFlow.pendingQueue {
                                castFlow.replace(with: [item])
                                showCastControls = true
                            }
                            castFlow.pendingQueue = nil
                        }
                        Button("Add to the queue") {
                            if let item = castFlow.pendingQueue {
                                castFlow.enqueue([item])
                            }
                            castFlow.pendingQueue = nil
                        }
                        Button("Cancel", role: .cancel) { castFlow.pendingQueue = nil }
                    } message: {
                        Text(castFlow.pendingQueue?.title ?? "")
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(PanuraTheme.background)
    }

    /// The bar for whichever TV has the video, or nil.
    ///
    /// Both cast paths end up here. They have nothing in common in the code —
    /// one is the Google Cast SDK, the other Panura's own receiver over a
    /// socket — but they are the same fact to a user: the video is on a
    /// television, and this is what it is and how to stop it.
    private var isCasting: Bool { panuraCast.isCasting || chromecast.isCasting }

    /// It is the bottom-most thing on screen now that the bar is gone, so its
    /// own ground has to reach the bottom of the display or the rounded corners
    /// cut the strip in half.
    private var castBarInset: CGFloat { AppChrome.bottomInset }

    @ViewBuilder
    private var castBar: some View {
        if panuraCast.isCasting {
            NowPlayingBar(
                icon: "tv.fill",
                title: panuraCast.streamTitle,
                where_: panuraCast.connectedTVName.isEmpty
                    ? "Playing on TV" : "On \(panuraCast.connectedTVName)",
                timeLeft: Self.timeLeft(
                    positionMs: panuraCast.playback.positionMs,
                    durationMs: panuraCast.playback.durationMs,
                    isLive: panuraCast.playback.isLive
                ),
                isPlaying: panuraCast.playback.isPlaying,
                // The remote, not the player: there is no local video to
                // return to, and the cast screen is where the tracks and the
                // scrubber are.
                onTap: { showCastControls = true },
                onPlayPause: {
                    panuraCast.playback.isPlaying ? panuraCast.pause() : panuraCast.play()
                },
                // Stops the video and keeps the TV. This used to call
                // PanuraCast's full teardown -- server, advertising and the
                // link -- while the Chromecast branch beside it stopped only
                // the media, so the same button meant two different things.
                onStop: { CastFlow.shared.stopCasting() },
                bottomInset: castBarInset
            )
        } else if chromecast.isCasting {
            NowPlayingBar(
                icon: "tv.fill",
                title: chromecast.castingTitle ?? "",
                where_: chromecast.connectedDeviceName.map { "On \($0)" } ?? "Playing on TV",
                timeLeft: chromecast.remoteTimeLeft,
                isPlaying: chromecast.isRemotePlaying,
                onTap: { showCastControls = true },
                onPlayPause: { chromecast.toggleRemotePlay() },
                onStop: { CastFlow.shared.stopCasting() },
                bottomInset: castBarInset
            )
        }
    }

    /// "12:04 left", or empty for a live stream or a receiver that has not
    /// reported a duration yet.
    private static func timeLeft(positionMs: Int64, durationMs: Int64, isLive: Bool) -> String {
        guard !isLive, durationMs > 0, durationMs > positionMs else { return "" }
        return PlayerClock.format(Double(durationMs - positionMs) / 1000) + " left"
    }

    /// All five, always composed. The outgoing one keeps the higher `zIndex`
    /// until it has faded, or the incoming one shows through it.
    private var destinations: some View {
        ZStack {
            layer(.home) {
                HomeView(
                    onOpenBrowser: { address in
                        pendingAddress = address
                        select(.web)
                    },
                    onOpenSection: select
                )
            }
            layer(.web) {
                BrowserView(
                    pendingAddress: $pendingAddress,
                    onGoHome: { select(.home) },
                    onOpenSettings: { screen in
                        settingsDeepLink = screen
                        showSettings = true
                    }
                )
            }
            layer(.videos) { LocalVideosView() }
            layer(.watchLater) {
                WatchLaterView(onOpenBrowser: { address in
                    pendingAddress = address
                    select(.web)
                })
            }
            layer(.stream) { StreamView() }
        }
    }

    @ViewBuilder
    private func layer<Content: View>(
        _ destination: AppDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let active = selection == destination
        content()
            // The bottom bar used to hold this strip for everyone. The browser
            // is the exception: it owns its own bottom edge, because the
            // found-video bar lives there and pads itself.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if destination != .web {
                    Color.clear.frame(height: AppChrome.bottomInset)
                }
            }
            .environment(\.destinationIsActive, active)
            .opacity(active ? 1 : 0)
            // A hidden layer must not eat taps meant for the visible one, and an
            // invisible screen should not be reachable by VoiceOver either.
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
    }

    private func select(_ destination: AppDestination) {
        session.showBar()
        dismissDrawerIfOverlay()
        // Settings opens over whatever you were doing and hands it back when it
        // closes, rather than replacing it.
        guard destination != .settings else {
            showSettings = true
            return
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            selection = destination
        }
    }

    /// The five places you can be, in one list.
    ///
    /// All of them, including the three that used to have seats in a bottom
    /// bar. Splitting destinations across a bar and a grid meant the split was
    /// by how often a place is visited rather than by what it is, and left
    /// Settings and Stream reachable only through a button that named neither.
    private var drawerDestinations: [AppDrawerPanel.Item] {
        AppDestination.allCases.map { destination in
            let here = selection == destination
            return AppDrawerPanel.Item(
                icon: destination.icon(selected: here),
                label: destination.title,
                detail: destination.detail,
                tint: destination.tint,
                isCurrent: here
            ) { select(destination) }
        }
    }

    /// Everything that is not a place.
    ///
    /// No Cast row: the mark for it is in the header of every screen, two
    /// centimetres above this list, and a drawer that repeats what the bar
    /// already offers teaches people the bar is not to be trusted.
    private var drawerActions: [AppDrawerPanel.Item] {
        var items: [AppDrawerPanel.Item] = [
            AppDrawerPanel.Item(
                icon: "questionmark.circle.fill", label: "Help",
                detail: "Answers, and how to reach us",
                tint: .blue
            ) { dismissDrawerIfOverlay(); showFAQ = true },
            AppDrawerPanel.Item(
                icon: "exclamationmark.bubble.fill", label: "Report a problem",
                detail: "A site that will not play, or anything broken",
                tint: .orange
            ) { dismissDrawerIfOverlay(); showReport = true },
        ]
        // Only once there is a listing to open. A Rate row that goes nowhere is
        // worse than no Rate row.
        if VersionStore.storeLinkReady {
            items.append(
                AppDrawerPanel.Item(
                    icon: "star.fill", label: "Rate Panura",
                    detail: "Leave a review on the App Store",
                    tint: .yellow
                ) {
                    dismissDrawerIfOverlay()
                    UIApplication.shared.open(VersionStore.storeURL)
                }
            )
        }
        return items
    }

    /// The TV in use, for the bar and the dialog that names it.
    private var castDeviceName: String? {
        if panuraCast.isTVConnected, !panuraCast.connectedTVName.isEmpty {
            return panuraCast.connectedTVName
        }
        return chromecast.connectedDeviceName
    }
}

#if DEBUG
/// Opens the player over the clip bundled into a screenshot build.
///
/// From the root rather than through the Videos tab, because reaching it that
/// way needs the photo library — and pre-granting Photos to the simulator with
/// `simctl privacy grant` is what hung three capture runs in a row.
private struct ScreenshotPlayerPresenter: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Through the session, like every other way of starting a video:
            // two fullScreenCovers on one view means only one of them ever
            // presents, and the session owns that one.
            .task {
                guard ScreenshotMode.wantsPlayer, let item = ScreenshotMode.demoItem else { return }
                PlaybackSession.shared.play(item)
            }
    }
}
#endif

private extension View {
    /// Itself in release builds. Written as a modifier rather than an `#if`
    /// inside the body's modifier chain, which is legal only on new enough
    /// compilers and not worth finding out about on a 16-minute CI cycle.
    @ViewBuilder
    func screenshotPlayer() -> some View {
        #if DEBUG
        modifier(ScreenshotPlayerPresenter())
        #else
        self
        #endif
    }
}
