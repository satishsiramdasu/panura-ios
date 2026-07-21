import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    NavigationLink("Cast to TV") { CastDevicesView() }
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
                ToolbarItem(placement: .topBarTrailing) { CastButton() }
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
