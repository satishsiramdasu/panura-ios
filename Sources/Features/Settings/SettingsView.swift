import SwiftUI

struct SettingsView: View {
    /// Read by VLCPlayerModel; when off, playback pauses on lock/background.
    @AppStorage("background_play") private var backgroundPlay = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Background playback", isOn: $backgroundPlay)
                    NavigationLink("Cast to TV") { CastDevicesView() }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Keep audio playing when you lock the screen or leave the app. Off by default.")
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
