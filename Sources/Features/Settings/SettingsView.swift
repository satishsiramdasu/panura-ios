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
                        description: "Resume, background play, skip, subtitles",
                        icon: "play.circle"
                    ) { PlaybackPreferencesView() }

                    PreferenceRow(
                        title: "Detection",
                        description: "Site rules, automatic play, diagnostics",
                        icon: "wave.3.right"
                    ) { DetectionPreferencesView() }

                    PreferenceRow(
                        title: "Cast to TV",
                        description: "Panura Cast and Chromecast",
                        icon: "tv"
                    ) { CastDevicesView() }
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
            .safeAreaInset(edge: .top) { PanuraHeader("Settings") }
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
            "background_play", "resume_playback", "skip_interval", "subtitle_size",
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
    /// Seconds the ±skip buttons and double-tap jump.
    @AppStorage("skip_interval") private var skipInterval = 10
    /// Default subtitle size (px); applied by VLCPlayerModel at media open.
    @AppStorage("subtitle_size") private var subtitleSize = 24

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

            Section("Controls") {
                Picker(selection: $skipInterval) {
                    Text("10 seconds").tag(10)
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                } label: {
                    PreferenceLabel(
                        title: "Skip interval",
                        description: "The ± buttons and the double-tap jump",
                        icon: "goforward"
                    )
                }
                Picker(selection: $subtitleSize) {
                    Text("Small").tag(16)
                    Text("Medium").tag(24)
                    Text("Large").tag(34)
                } label: {
                    PreferenceLabel(
                        title: "Subtitle size",
                        description: "Applied when a video opens",
                        icon: "captions.bubble"
                    )
                }
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
