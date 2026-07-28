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
                    Toggle("Diagnostics", isOn: $debugDetection)
                } header: {
                    Text("Detection")
                } footer: {
                    Text("Re-downloads the site detection rules. Reopen the Browser tab afterwards to apply them.\n\nDiagnostics logs every media URL a page requests and why it was kept or filtered, shown under the detected-videos sheet.")
                }

                Section("Community") {
                    Link(destination: URL(string: "https://t.me/")!) {
                        Label("Join our Telegram", systemImage: "paperplane.fill")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Link("Privacy Policy", destination: URL(string: "https://panura.pages.dev/privacy")!)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { CastButton() }
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
