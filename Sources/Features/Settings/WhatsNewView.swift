import SwiftUI

/// The full version history, from the same `version.json` the update check
/// reads — not from anything baked into the build. So it is whatever the CDN is
/// serving, the release process has one less thing to remember, and old entries
/// age out on their own with the build's ten-per-platform cap.
struct WhatsNewView: View {
    @ObservedObject private var versions = VersionStore.shared

    var body: some View {
        List {
            if versions.updateAvailable, VersionStore.storeLinkReady,
               let latest = versions.ios?.versionName {
                Section {
                    Link(destination: VersionStore.storeURL) {
                        Label("Update to \(latest)", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                } footer: {
                    Text("You are on \(VersionStore.installedVersionName).")
                }
            }

            ForEach(versions.ios?.changelog ?? []) { release in
                Section {
                    ForEach(release.notes, id: \.self) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(note).font(.subheadline)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(release.versionName)
                        // The running build wears a chip, so the list says where
                        // you are as well as what changed.
                        if release.versionName == VersionStore.installedVersionName {
                            Text("Installed")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(PanuraTheme.accentSoft, in: Capsule())
                                .foregroundStyle(PanuraTheme.accent)
                        }
                        Spacer()
                        if !release.date.isEmpty {
                            Text(release.displayDate).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if versions.ios?.changelog.isEmpty ?? true {
                Section {
                    if versions.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading release notes…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Release notes couldn't be loaded. Check your connection and try again.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PanuraTheme.background)
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
        .task { await versions.load() }
        .refreshable { await versions.load(force: true) }
    }
}
