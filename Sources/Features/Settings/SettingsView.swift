import SwiftUI

struct SettingsView: View {
    /// Read by VLCPlayerModel; when off, playback pauses on lock/background.
    @AppStorage("background_play") private var backgroundPlay = false
    /// Read by VLCPlayerModel — resume each video from where it was left.
    @AppStorage("resume_playback") private var resumePlayback = true
    /// Seconds the ±skip buttons and double-tap jump.
    @AppStorage("skip_interval") private var skipInterval = 10
    /// Default subtitle size (px); applied by VLCPlayerModel at media open.
    @AppStorage("subtitle_size") private var subtitleSize = 24
    @State private var rulesRefreshed = false
    /// Read by WebViewContainer at web-view creation and by the found-videos sheet.
    @AppStorage("debug_detection") private var debugDetection = false
    /// Read by WebViewContainer at web-view creation. The one injection that
    /// touches the page rather than observing it, so it gets a switch.
    @AppStorage("auto_play_click") private var autoPlayClick = true
    @ObservedObject private var versions = VersionStore.shared
    @State private var checkedForUpdates = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Background playback", isOn: $backgroundPlay)
                    Toggle("Resume from last position", isOn: $resumePlayback)
                    Picker("Skip interval", selection: $skipInterval) {
                        Text("10s").tag(10); Text("15s").tag(15); Text("30s").tag(30)
                    }
                    Picker("Subtitle size", selection: $subtitleSize) {
                        Text("Small").tag(16); Text("Medium").tag(24); Text("Large").tag(34)
                    }
                    NavigationLink("Cast to TV") { CastDevicesView() }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Background playback keeps audio going when you lock the screen or leave the app. Skip interval sets the ±buttons and double-tap jump.")
                }
                Section {
                    Button {
                        ManifestStore.clearCache()
                        rulesRefreshed = true
                    } label: {
                        Label(
                            rulesRefreshed ? "Site rules will refresh" : "Refresh site rules",
                            systemImage: rulesRefreshed ? "checkmark" : "arrow.clockwise"
                        )
                    }
                    .disabled(rulesRefreshed)
                    Toggle("Press play automatically", isOn: $autoPlayClick)
                    Toggle("Diagnostics", isOn: $debugDetection)
                } header: {
                    Text("Detection")
                } footer: {
                    Text("Re-downloads the site detection rules. Reopen the Browser tab afterwards to apply them.\n\nSome sites request nothing until their play button is pressed; Panura presses it for them so the stream can be found. Turn this off first if a page starts behaving oddly on load.\n\nDiagnostics logs every media URL a page requests and why it was kept or filtered, shown under the detected-videos sheet.")
                }

                Section("Community") {
                    Link(destination: URL(string: "https://t.me/")!) {
                        Label("Join our Telegram", systemImage: "paperplane.fill")
                    }
                }
                Section {
                    LabeledContent("Version", value: appVersion)
                    NavigationLink {
                        WhatsNewView()
                    } label: {
                        Label("What's New", systemImage: "sparkles")
                    }
                    Button {
                        Task {
                            await versions.load(force: true)
                            checkedForUpdates = true
                        }
                    } label: {
                        HStack {
                            Label("Check for Updates", systemImage: "arrow.down.circle")
                            Spacer()
                            if versions.isLoading { ProgressView() }
                        }
                    }
                    .disabled(versions.isLoading)
                    // Only ever shown when there is something to go and get.
                    if versions.updateAvailable, let latest = versions.ios?.versionName {
                        Link(destination: VersionStore.storeURL) {
                            Label("Update to \(latest)", systemImage: "arrow.up.forward.app")
                                .foregroundStyle(PanuraTheme.accent)
                        }
                    }
                    Link("Privacy Policy", destination: URL(string: "https://panura.pages.dev/privacy")!)
                } header: {
                    Text("About")
                } footer: {
                    if checkedForUpdates, !versions.isLoading, !versions.updateAvailable {
                        Text("You're on the latest version.")
                    }
                }
            }
            // The app's own header instead of a nav bar: the glyph, the title
            // and the cast control hold the same pixel on every screen, which is
            // what stops a destination switch from looking like leaving the app.
            // Pushed screens keep their normal bar, so back stays where iOS
            // users expect it.
            .safeAreaInset(edge: .top) { PanuraHeader("Settings") }
            .navigationBarHidden(true)
            .task { await versions.load() }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
