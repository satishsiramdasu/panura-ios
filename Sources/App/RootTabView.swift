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
            case "settings": return .settings
            default: return .home
            }
        }
        #endif
        return .home
    }()
    @State private var showMenu = false
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

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                destinations
                // Hidden while the browser is scrolled down, and only there: the
                // page needs the height, and every other destination is a list
                // that can reach its own end. The height animates away in place
                // rather than the bar sliding over the content, so nothing it
                // covers can end up unreachable.
                // Above the app bar, below everything else: the television
                // that has the video.
                //
                // Only a television. Picture in Picture had a bar here too, and
                // it was redundant every single time it appeared: `minimized`
                // is set by exactly one thing, the PiP hand-off, so the bar
                // could never be on screen without iOS already floating the
                // video above it — with pause, close and restore on the window
                // itself, closer to hand than a strip at the bottom. Casting is
                // the opposite. Nothing on the phone shows it at all, which is
                // what earns a permanent strip.
                if isCasting {
                    castBar.transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if barVisible {
                    AppBarRow(
                        selection: selection,
                        menuOpen: showMenu,
                        onSelect: select,
                        onToggleMenu: {
                            withAnimation(.easeOut(duration: 0.2)) { showMenu.toggle() }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: barVisible)

            if showMenu {
                // Scrim first: dismisses on tap without stealing the panel's own
                // taps. It stops at the bar, so the control that opened the panel
                // is the one that closes it.
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showMenu = false } }

                // Rests on the bar: the whole stack shares one bottom edge (see
                // below), so the panel only has to clear the bar's own height.
                AppMenuPanel(items: menuItems, current: selection)
                    .padding(.bottom, AppBarRow.totalHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // One bottom edge for everything in the stack — the screen's, not the
        // safe area's. Applied here rather than to the bar and the panel
        // separately: two views each ignoring the safe area on their own end up
        // measured against different bottoms, which is exactly how the panel
        // came to float an indicator's height above the bar.
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

    /// The bar for whichever TV has the video, or nil.
    ///
    /// Both cast paths end up here. They have nothing in common in the code —
    /// one is the Google Cast SDK, the other Panura's own receiver over a
    /// socket — but they are the same fact to a user: the video is on a
    /// television, and this is what it is and how to stop it.
    private var isCasting: Bool { panuraCast.isCasting || chromecast.isCasting }

    /// With the app bar away — most of a scrolled browser page — this is the
    /// bottom-most thing on screen, and its own ground has to reach the bottom
    /// of the display or the rounded corners cut the strip in half.
    private var castBarInset: CGFloat { barVisible ? 0 : AppBarRow.bottomInset }

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
                        select(.settings)
                    }
                )
            }
            layer(.videos) { LocalVideosView() }
            layer(.stream) { StreamView() }
            layer(.settings) { SettingsView(deepLink: $settingsDeepLink) }
        }
    }

    @ViewBuilder
    private func layer<Content: View>(
        _ destination: AppDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let active = selection == destination
        content()
            .environment(\.destinationIsActive, active)
            .opacity(active ? 1 : 0)
            // A hidden layer must not eat taps meant for the visible one, and an
            // invisible screen should not be reachable by VoiceOver either.
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
    }

    /// The bar can only be hidden by the browser, and only while you are in it
    /// — leaving the Web tab must never strand it off screen.
    private var barVisible: Bool {
        selection != .web || session.barVisible || showMenu
    }

    private func select(_ destination: AppDestination) {
        session.showBar()
        withAnimation(.easeInOut(duration: 0.22)) {
            selection = destination
            showMenu = false
        }
    }

    /// What the grid holds: the destinations with no seat in the bar.
    ///
    /// Cast is deliberately NOT here. It is a control rather than a place, it
    /// has to be reachable from whatever screen you are on, and it now lives
    /// top-right in the header of every one of them — same slot as Android's.
    /// Everything without a seat in the bar.
    ///
    /// Deliberately not Browser and Videos as well: they have seats two
    /// centimetres below this panel, and a menu that repeats the bar teaches
    /// people the bar is not to be trusted. What belongs here is what has
    /// nowhere else to be.
    private var menuItems: [AppMenuPanel.Item] {
        var items: [AppMenuPanel.Item] = [
            AppMenuPanel.Item(
                icon: "tv.badge.wifi", label: "Cast to TV",
                detail: isCasting ? "Playing on \(castDeviceName ?? "your TV")" : "Find a television",
                tint: PanuraTheme.accent
            ) {
                showMenu = false
                if isCasting { showCastControls = true } else { CastPicker.shared.open() }
            },
            AppMenuPanel.Item(
                icon: "link", label: "Network Stream",
                detail: "Play a link straight from its address",
                tint: .cyan
            ) { select(.stream) },
            AppMenuPanel.Item(
                icon: "gearshape.fill", label: "Settings",
                detail: "Playback, browser, subtitles, gestures",
                tint: .gray
            ) { select(.settings) },
            AppMenuPanel.Item(
                icon: "questionmark.circle.fill", label: "Help",
                detail: "Answers, and how to reach us",
                tint: .blue
            ) { showMenu = false; showFAQ = true },
            AppMenuPanel.Item(
                icon: "exclamationmark.bubble.fill", label: "Report a problem",
                detail: "A site that will not play, or anything broken",
                tint: .orange
            ) { showMenu = false; showReport = true },
        ]
        // Only once there is a listing to open. A Rate row that goes nowhere is
        // worse than no Rate row.
        if VersionStore.storeLinkReady {
            items.append(
                AppMenuPanel.Item(
                    icon: "star.fill", label: "Rate Panura",
                    detail: "Leave a review on the App Store",
                    tint: .yellow
                ) {
                    showMenu = false
                    UIApplication.shared.open(VersionStore.storeURL)
                }
            )
        }
        return items
    }

    /// The TV in use, for the menu row that says so.
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
