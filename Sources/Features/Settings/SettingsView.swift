import SwiftUI

/// Settings root, structured like Android's `GeneralPreferencesScreen`: a short
/// list of sections, each row naming a screen and saying what is in it. Nothing
/// is set here — the root is a map, and every switch lives on the screen it
/// belongs to.
struct SettingsView: View {
    @State private var confirmReset = false
    @State private var didReset = false

    var body: some View {
        NavigationStack {
            List {
                Section("Settings") {
                    PreferenceRow(
                        title: "Web Browser",
                        description: "Ad blocker, private browsing, clear data",
                        icon: "globe"
                    ) { BrowserPreferencesView() }

                    PreferenceRow(
                        title: "Playback",
                        description: "Resume, background play, speed",
                        icon: "play.circle"
                    ) { PlaybackPreferencesView() }

                    PreferenceRow(
                        title: "Subtitles",
                        description: "Size, font, colour, encoding, language",
                        icon: "captions.bubble"
                    ) { SubtitlePreferencesView() }

                    PreferenceRow(
                        title: "Gestures",
                        description: "Swipes, taps, skip interval, sensitivity",
                        icon: "hand.draw"
                    ) { GesturePreferencesView() }

                    PreferenceRow(
                        title: "Local Videos",
                        description: "How the Videos tab lists what it finds",
                        icon: "film"
                    ) { LocalVideoPreferencesView() }

                    PreferenceRow(
                        title: "Detection",
                        description: "Site rules, automatic play, diagnostics",
                        icon: "wave.3.right"
                    ) { DetectionPreferencesView() }
                }

                Section("More") {
                    PreferenceRow(
                        title: "About",
                        description: "Version, support, credits",
                        icon: "info.circle"
                    ) { AboutView() }

                    PreferenceRow(
                        title: "Support",
                        description: "Get help or report an issue",
                        icon: "ladybug"
                    ) { SupportView() }
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
            "mark_last_played", "show_extension", "videos_layout",
            "debug_detection", "auto_play_click", "ad_block", "desktop_mode_default",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        didReset = true
    }
}

// MARK: - Playback

struct PlaybackPreferencesView: View {
    /// Read by VLCPlayerModel; when off, playback pauses on lock/background.
    @AppStorage("background_play") private var backgroundPlay = false
    /// Read by VLCPlayerModel — resume each video from where it was left.
    @AppStorage("resume_playback") private var resumePlayback = true
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

// MARK: - Detection

struct DetectionPreferencesView: View {
    @AppStorage("debug_detection") private var debugDetection = false
    @AppStorage("auto_play_click") private var autoPlayClick = true
    @State private var rulesRefreshed = false

    var body: some View {
        List {
            Section {
                PreferenceButton(
                    title: rulesRefreshed ? "Site rules will refresh" : "Refresh site rules",
                    description: "Re-download the detection rules. Reopen the Web tab to apply them.",
                    icon: rulesRefreshed ? "checkmark" : "arrow.down.circle"
                ) {
                    ManifestStore.clearCache()
                    rulesRefreshed = true
                }
                .disabled(rulesRefreshed)
            } header: {
                Text("Rules")
            } footer: {
                Text("Detection rules are fetched from Panura's servers, so a site that stops working can be fixed without an app update.")
            }

            Section("Behaviour") {
                PreferenceToggle(
                    title: "Press play automatically",
                    description: "Some sites request nothing until their play button is pressed; Panura presses it for them",
                    icon: "play.square",
                    isOn: $autoPlayClick
                )
            }

            Section {
                PreferenceToggle(
                    title: "Diagnostics",
                    description: "Log every media URL a page requests and why it was kept or filtered",
                    icon: "ladybug",
                    isOn: $debugDetection
                )
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("The log appears under the detected-videos sheet in the browser.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("Detection")
        .navigationBarTitleDisplayMode(.inline)
    }
}
