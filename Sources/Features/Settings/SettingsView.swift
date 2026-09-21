import SwiftUI

/// Settings root, structured like Android's `GeneralPreferencesScreen`: a short
/// list of sections, each row naming a screen and saying what is in it. Nothing
/// is set here — the root is a map, and every switch lives on the screen it
/// belongs to.
/// A settings screen that something outside Settings can ask for by name.
///
/// Every row on the root is one of these, so the navigation stack's `path` is
/// the complete truth about where it is — which is what lets the browser send
/// someone straight to Browser settings from wherever they left it.
enum SettingsScreen: Hashable {
    // No `detection`: those settings moved under Web Browser, where the
    // switch they all depend on already lived. A screen of its own put the
    // app's most specialised options at the same level as "Playback".
    case browser, playback, subtitles, gestures, localVideos, about, support
}

struct SettingsView: View {
    /// Set by whoever opened Settings to land somewhere other than the root.
    /// Cleared once acted on, so Back returns to the root rather than bouncing
    /// straight in again.
    var deepLink: Binding<SettingsScreen?> = .constant(nil)

    @State private var confirmReset = false
    @State private var didReset = false
    @State private var path: [SettingsScreen] = []

    var body: some View {
        content
            // Unanimated: opening Browser settings from the browser should land
            // there, not show the root list sliding past on the way. The root
            // stays underneath, so Back still means what it says.
            .onChange(of: deepLink.wrappedValue) { goTo($0) }
            .onAppear { goTo(deepLink.wrappedValue) }
    }

    /// Replaces the path rather than appending to it — whatever screen was left
    /// open last time goes, which is the bug this exists to fix.
    private func goTo(_ screen: SettingsScreen?) {
        guard let screen else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { path = [screen] }
        deepLink.wrappedValue = nil
    }

    private var content: some View {
        NavigationStack(path: $path) {
            List {
                Section("Settings") {
                    PreferenceLink(
                        title: "Web Browser",
                        description: "Hide distractions, private browsing, finding videos",
                        icon: "globe",
                        value: SettingsScreen.browser
                    )

                    PreferenceLink(
                        title: "Playback",
                        description: "Resume, background play, speed",
                        icon: "play.circle",
                        value: SettingsScreen.playback
                    )

                    PreferenceLink(
                        title: "Subtitles",
                        description: "Size, font, colour, encoding, language",
                        icon: "captions.bubble",
                        value: SettingsScreen.subtitles
                    )

                    PreferenceLink(
                        title: "Gestures",
                        description: "Swipes, taps, skip interval, sensitivity",
                        icon: "hand.draw",
                        value: SettingsScreen.gestures
                    )

                    PreferenceLink(
                        title: "Local Videos",
                        description: "How the Videos tab lists what it finds",
                        icon: "film",
                        value: SettingsScreen.localVideos
                    )
                }

                Section("More") {
                    PreferenceLink(
                        title: "About",
                        description: "Version, support, credits",
                        icon: "info.circle",
                        value: SettingsScreen.about
                    )

                    PreferenceLink(
                        title: "Support",
                        description: "Get help or report an issue",
                        icon: "ladybug",
                        value: SettingsScreen.support
                    )
                }

                Section {
                    PreferenceButton(
                        title: "Reset settings",
                        description: didReset
                            ? "Defaults restored"
                            : "Restore every setting to its default",
                        icon: didReset ? "checkmark" : "arrow.counterclockwise",
                        tint: didReset ? PanuraTheme.success : PanuraTheme.error
                    ) { confirmReset = true }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Shortcuts, history and Continue Watching are kept — this resets preferences only.")
                }
            }
            .navigationDestination(for: SettingsScreen.self) { screen in
                switch screen {
                case .browser: BrowserPreferencesView()
                case .playback: PlaybackPreferencesView()
                case .subtitles: SubtitlePreferencesView()
                case .gestures: GesturePreferencesView()
                case .localVideos: LocalVideoPreferencesView()
                case .about: AboutView()
                case .support: SupportView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(PanuraTheme.background)
            // The app's own header instead of a nav bar: the glyph, the title
            // and the cast control hold the same pixel on every screen, which is
            // what stops a destination switch from looking like leaving the app.
            // Pushed screens keep their normal bar, so back stays where iOS
            // users expect it.
            .safeAreaInset(edge: .top, spacing: 0) { PanuraHeader("Settings") }
            .navigationBarHidden(true)
            .confirmationDialog(
                "Reset settings?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Playback, browser and detection preferences go back to their defaults.")
            }
        }
    }

    /// Preferences only. Shortcuts, history and resume points are things the
    /// user made rather than settings, and Android's reset leaves them alone
    /// too.
    private func reset() {
        let keys = [
            "background_play", "resume_playback", "skip_interval", "default_playback_speed",
            "subtitle_size", "subtitle_color", "subtitle_background", "subtitle_bold",
            "subtitle_outline", "subtitle_font", "subtitle_encoding",
            "subtitle_embedded_styles", "preferred_subtitle_language",
            "preferred_audio_language",
            "gesture_seek", "gesture_brightness", "gesture_volume", "gesture_zoom",
            "gesture_double_tap", "gesture_long_press", "gesture_sensitivity",
            "mark_last_played", "show_extension", "videos_layout", "player_engine_mode",
            "debug_detection", "auto_play_click", "block_page_fullscreen", "ad_block",
            "block_long_press",
            "desktop_mode_default", "detection_enabled",
            // Every per-site override too: "back to defaults" that left a site
            // with detection switched off would not be back to defaults.
            "site_settings",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        didReset = true
    }
}

// MARK: - Playback

struct PlaybackPreferencesView: View {
    /// Read by both players; when off, playback pauses on lock/background.
    @AppStorage("background_play") private var backgroundPlay = false
    /// Read by both players — resume each video from where it was left.
    @AppStorage("resume_playback") private var resumePlayback = true
    /// Which engine plays. Auto picks per video; the other two force one.
    @AppStorage(PlayerEngineKind.defaultsKey)
    private var playerEngine: String = PlayerEngineKind.auto.rawValue
    /// Rate every video opens at; the player's speed control overrides it.
    @AppStorage("default_playback_speed") private var defaultSpeed = 1.0

    var body: some View {
        List {
            Section {
                PreferenceToggle(
                    title: "Background playback",
                    description: "Keep audio going when you lock the screen or leave the app",
                    icon: "speaker.wave.2",
                    isOn: $backgroundPlay
                )
                PreferenceToggle(
                    title: "Resume from last position",
                    description: "Start each video where you left it",
                    icon: "arrow.clockwise",
                    isOn: $resumePlayback
                )
            } header: {
                Text("Playback")
            }

            Section {
                Picker(selection: $playerEngine) {
                    ForEach(PlayerEngineKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                } label: {
                    PreferenceLabel(
                        title: "Player",
                        description: "Which engine opens videos",
                        icon: "play.rectangle"
                    )
                }
                .pickerStyle(.menu)
                .tint(PanuraTheme.accent)
            } header: {
                Text("Engine")
            } footer: {
                Text("Auto plays videos in the Apple player, with Picture in Picture, AirPlay and HDR, and switches to VLC by itself when a video's format needs it.")
            }

            Section {
                Picker(selection: $defaultSpeed) {
                    Text("0.75×").tag(0.75)
                    Text("Normal").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                } label: {
                    PreferenceLabel(
                        title: "Default speed",
                        description: "Every video starts at this rate",
                        icon: "speedometer"
                    )
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("The player's own speed control still applies per video; this is only where it starts.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }
}

