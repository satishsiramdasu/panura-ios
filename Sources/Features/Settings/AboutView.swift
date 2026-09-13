import Foundation
import SwiftUI

/// Port of Android's `AboutPreferencesScreen`: the app card, the two version
/// actions, the links, and the device-info block that makes a bug report
/// answerable.
struct AboutView: View {
    @ObservedObject private var versions = VersionStore.shared
    @State private var checked = false
    @State private var showShare = false

    private var appVersion: String {
        let name = VersionStore.installedVersionName
        let code = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(name) (\(code))"
    }

    var body: some View {
        List {
            Section { appCard.listRowInsets(EdgeInsets()) }
                .listRowBackground(Color.clear)

            Section {
                PreferenceButton(
                    title: versions.isLoading ? "Checking…" : "Check for Updates",
                    description: updateDescription,
                    icon: versions.updateAvailable ? "arrow.down.circle.fill" : "arrow.down.circle"
                ) {
                    Task {
                        await versions.load(force: true)
                        checked = true
                    }
                }
                .disabled(versions.isLoading)

                PreferenceRow(
                    title: "What's New",
                    description: "Every release and what it changed",
                    icon: "sparkles"
                ) { WhatsNewView() }

                if versions.updateAvailable, VersionStore.storeLinkReady,
                   let latest = versions.ios?.versionName {
                    Link(destination: VersionStore.storeURL) {
                        PreferenceLabel(
                            title: "Update to \(latest)",
                            description: "Open the App Store",
                            icon: "arrow.up.forward.app"
                        )
                    }
                }
            } header: {
                Text("Version")
            }

            Section("Links") {
                Link(destination: URL(string: "https://panura.app/privacy")!) {
                    PreferenceLabel(
                        title: "Privacy Policy",
                        description: "What Panura collects, and what it does not",
                        icon: "hand.raised"
                    )
                }
                Link(destination: URL(string: "https://panura.app/terms")!) {
                    PreferenceLabel(
                        title: "Terms of Use",
                        description: "What the app may be used for",
                        icon: "doc.text"
                    )
                }
                Link(destination: URL(string: "https://t.me/panura_player")!) {
                    PreferenceLabel(
                        title: "Join our Telegram",
                        description: "Release news and help from other users",
                        icon: "paperplane"
                    )
                }
                Button { showShare = true } label: {
                    PreferenceLabel(
                        title: "Share Panura",
                        description: "Send the app to someone",
                        icon: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.plain)
            }

            Section("Device info") {
                infoRow("App version", appVersion)
                infoRow("iOS version", UIDevice.current.systemVersion)
                infoRow("Device", UIDevice.current.model)
                infoRow("Model", Self.hardwareModel)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .task { await versions.load() }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [
                URL(string: "https://panura.app")!,
                "Panura Player — browse, play and cast web video.",
            ])
        }
    }

    private var updateDescription: String {
        if versions.updateAvailable, let latest = versions.ios?.versionName {
            return "Version \(latest) is available"
        }
        if checked { return "You're on the latest version" }
        return "Ask the server what the newest build is"
    }

    /// The app's own card, matching Android's gradient block: icon, name, and
    /// the version people are asked for when they report something.
    private var appCard: some View {
        HStack(spacing: 16) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Panura").font(.title2)
                Text(appVersion)
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [PanuraTheme.accentContainer, PanuraTheme.surfaceContainer],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: PanuraTheme.cornerMedium)
        )
        .padding(.vertical, 4)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Spacer()
            Text(value).font(.footnote)
        }
    }

    /// "iPhone15,3" — the identifier a crash report is filed under, which
    /// `UIDevice.model` ("iPhone") does not give.
    private static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.isEmpty ? "Unknown" : machine
    }
}

/// Support screen — Android's, with the same two ways out plus the report form.
struct SupportView: View {
    @State private var showReport = false

    var body: some View {
        List {
            Section {
                Button { showReport = true } label: {
                    PreferenceLabel(
                        title: "Report an issue",
                        description: "Tell us what went wrong; it reaches the same place as a page report",
                        icon: "ladybug"
                    )
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: "https://panura.app/support")!) {
                    PreferenceLabel(
                        title: "Help & FAQ",
                        description: "Answers to the things that go wrong most often",
                        icon: "questionmark.circle"
                    )
                }
                Link(destination: URL(string: "mailto:strapps@proton.me")!) {
                    PreferenceLabel(
                        title: "Send email",
                        description: "strapps@proton.me",
                        icon: "envelope"
                    )
                }
                Link(destination: URL(string: "https://t.me/panura_player")!) {
                    PreferenceLabel(
                        title: "Join our Telegram",
                        description: "Release news and help from other users",
                        icon: "paperplane"
                    )
                }
            } header: {
                Text("Get help")
            } footer: {
                Text("A report is most useful with the site's address and what you saw — the version and device are attached for you.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showReport) { ReportIssueSheet(source: "settings") }
    }
}

/// `ShareLink` cannot carry two items of different types, and the share sheet
/// wants both the URL and a line of text.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
