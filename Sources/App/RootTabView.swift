import UIKit
import SwiftUI

/// The app's shell: one header, a row of tabs under it, and every destination
/// stacked below that.
///
///     ShellHeader     mark · Panura · tagline or the TV      cast   menu
///     ShellTabBar     Browser   Videos   Network   +
///     content         the destination, then the cast bar
///
/// **The drawer is gone.** Navigation used to be a slide-over list on the phone
/// and a rail on the iPad, with every destination in it including the ones you
/// visit constantly. A list is the right shape for places you go rarely and the
/// wrong one for places you live in — it hid the three main destinations behind
/// a press, and the rail then spent iPad width restating them. The tabs say
/// where you can be without being asked, and what is left over — Settings,
/// Watch Later, Help, Report, Rate, About — is a menu, because none of those is
/// a place you stay.
///
/// Home went with it, into the Browser tab as its landing screen. Four seats is
/// the ceiling at phone width and Home is the one you leave immediately.
///
/// Still deliberately NOT a `TabView`: a `UITabBar` cannot draw a tab that
/// joins the panel beneath it, and that join is what says the strip and the
/// content are one thing.
///
/// Every destination stays composed and is hidden by opacity rather than being
/// rebuilt. The browser owns a live `WKWebView`, a page mid-load and a set of
/// detections; a trip to Home or to Videos must not cost any of that.
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
            default: return .home
            }
        }
        #endif
        // Where they were last time, unless that was the browser - see
        // `TabSet.openingTab`.
        return TabSet.openingTab()
    }()

    /// Watch Later is a sheet, for the reason Settings is one: it is somewhere
    /// you go from wherever you are and come straight back out of. As a
    /// destination it would be a place with no tab, and nothing in the strip
    /// would look selected while you were in it.
    @State private var showWatchLater = false
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
    /// Network Stream, which is a sheet for the same reason Watch Later is:
    /// a URL field and a Play button, used once and left. As a tab it was a
    /// quarter of the row spent on something nobody opens twice in a session.
    @State private var showStream = false
    @ObservedObject private var chrome = ShellChrome.shared
    @ObservedObject private var tabSet = TabSet.shared

    var body: some View {
        shell
        .background(deepChrome.ignoresSafeArea())
        // The header hides the moment you leave Home, and comes back when you
        // return to it. Driven from the selection rather than from inside
        // `select` so it is also right on launch and after a deep link.
        .onChange(of: selection) { destination in
            chrome.destinationChanged(to: destination)
            tabSet.remember(destination)
        }
        .onAppear { chrome.destinationChanged(to: selection) }
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
        .sheet(isPresented: $showStream) { StreamView() }
        .sheet(isPresented: $showWatchLater) {
            LibrarySheet(tab: .later) { address in
                showWatchLater = false
                openInBrowser(address)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(deepLink: $settingsDeepLink)
        }
        .task {
            #if DEBUG
            if ScreenshotMode.isActive, ScreenshotMode.screen == "settings" {
                showSettings = true
            }
            // Both of these are sheets rather than destinations, so the capture
            // run opens them instead of launching into them.
            if ScreenshotMode.isActive, ScreenshotMode.screen == "stream" {
                showStream = true
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

    /// The app, top to bottom: who it is, where you can go, where you are, and
    /// the television when there is one.
    ///
    /// One header for the whole app rather than one per screen. A screen still
    /// draws a bar of its own where it needs one — the browser's address pill
    /// above all — but that bar is about the screen now, not about the app,
    /// which is why the mark, the cast control and the menu moved up here and
    /// stopped being repeated on four screens.
    private var shell: some View {
        ZStack {
            VStack(spacing: 0) {
                // Both collapse their height in place rather than sliding over
                // the content, so nothing either of them covers can end up out
                // of reach - the same rule the browser's address bar follows.
                // One block, one height. The header and the strip used to
                // collapse on separate flags, which put two things in motion in
                // the same corner at two different moments; they are the top of
                // the app, so they go together.
                VStack(spacing: 0) {
                    ShellHeader(
                        connectedTV: castDeviceName,
                        ground: deepChrome
                    ) { menuRows }

                    ShellTabBar(
                        tabs: tabSet.tabs,
                        selection: $selection,
                        addable: tabSet.offerable,
                        onSelect: select,
                        onAdd: addTab,
                        ground: deepChrome,
                        privateBrowsing: session.privateMode
                    )
                }
                .frame(height: chrome.visible ? Self.chromeHeight : 0, alignment: .bottom)
                .opacity(chrome.visible ? 1 : 0)
                .clipped()

                content
            }
            // Above every screen, because the mark that opens it is in the
            // header and the panel has to cover what it is about.
            CastPanelOverlay()
        }
    }

    /// The tone behind the header and the tab strip: the selected
    /// destination's, violet while the browser is private.
    private var deepChrome: Color {
        selection.chromeDeep(privateBrowsing: session.privateMode)
    }

    /// Header plus strip. Collapsed as one height, so the strip slides out
    /// under the header rather than the two of them racing.
    private static var chromeHeight: CGFloat {
        ShellHeader<EmptyView>.height + ShellTabBar.height
    }

    /// Puts a tab in the strip and goes to it, in one motion.
    ///
    /// Adding and arriving are the same gesture on purpose. Somebody who picks
    /// IPTV from the `+` wants IPTV, not a new button to press afterwards.
    private func addTab(_ destination: AppDestination) {
        tabSet.add(destination)
        select(destination)
    }

    /// Everything that is not a place.
    ///
    /// No Cast row: the control for it is in the same header, four centimetres
    /// away, and a menu that repeats what the bar already offers teaches people
    /// the bar is not to be trusted.
    @ViewBuilder
    private var menuRows: some View {
        Button {
            settingsDeepLink = nil
            showSettings = true
        } label: { Label("Settings", systemImage: "gearshape") }

        Button { showWatchLater = true } label: {
            Label("Watch Later", systemImage: "clock")
        }

        Button { showFAQ = true } label: {
            Label("Help", systemImage: "questionmark.circle")
        }

        Button { showReport = true } label: {
            Label("Report a problem", systemImage: "exclamationmark.bubble")
        }

        // Only once there is a listing to open. A Rate row that goes nowhere is
        // worse than no Rate row.
        if VersionStore.storeLinkReady {
            Button {
                UIApplication.shared.open(VersionStore.storeURL)
            } label: { Label("Rate Panura", systemImage: "star") }
        }

        Button {
            settingsDeepLink = .about
            showSettings = true
        } label: { Label("About", systemImage: "info.circle") }
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

    /// Every tab in the strip, always composed. The outgoing one keeps the
    /// higher `zIndex` until it has faded, or the incoming one shows through
    /// it.
    private var destinations: some View {
        ZStack {
            layer(.home) {
                HomeView(
                    onOpenBrowser: openInBrowser,
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
            layer(.iptv) { IPTVView() }
            // Only the ones that are actually in the strip. A destination
            // nobody has added is not composed at all, which is the difference
            // between an opt-in tab and a hidden one.
            ForEach(tabSet.added, id: \.self) { destination in
                layer(destination) { added(destination) }
            }
        }
    }

    /// A tab somebody added from the `+`. Only Server is offered — see
    /// `TabSet.addable` — and `TabSet.storedTabs` filters anything else out
    /// before it reaches here.
    @ViewBuilder
    private func added(_ destination: AppDestination) -> some View {
        switch destination {
        case .ftp: NetworkServerView()
        default: EmptyView()
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
            // So a screen can colour its own bar to match the tab it belongs
            // to, without having to know which destination it is.
            .environment(
                \.screenChrome,
                destination.chrome(privateBrowsing: session.privateMode)
            )
            .opacity(active ? 1 : 0)
            // A hidden layer must not eat taps meant for the visible one, and an
            // invisible screen should not be reachable by VoiceOver either.
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
    }

    /// Opens an address in the browser half of the Browser tab, from wherever
    /// asked — Home's pill, Watch Later, a resume card.
    private func openInBrowser(_ address: String) {
        pendingAddress = address
        withAnimation(.easeInOut(duration: 0.22)) { selection = .web }
    }

    private func select(_ destination: AppDestination) {
        session.showBar()
        switch destination {
        // These open over whatever you were doing and hand it back when they
        // close, rather than replacing it.
        case .settings:
            showSettings = true
            return
        case .watchLater:
            showWatchLater = true
            return
        case .stream:
            showStream = true
            return
        default:
            break
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            selection = destination
        }
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
