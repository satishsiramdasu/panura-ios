import SwiftUI
import WebKit

/// "Erase data and exit" — the panic button, from Home's Clear menu.
///
/// A checklist rather than one destructive button, because the things it can
/// erase are not equally regrettable. History and cookies are traces; bookmarks
/// and Watch Later are work. The two that took effort to create default to off
/// and have to be asked for, which is also how the app this pattern is borrowed
/// from does it.
///
/// **On quitting.** `exit(0)` is against Apple's HIG, which says an app should
/// never terminate itself because users read it as a crash. It is shipped here
/// anyway: Web Video Caster carries the same "erase all data and exit" and has
/// been on the App Store for years, which is direct evidence that review
/// accepts it for this kind of app. If it is ever cited in a rejection, delete
/// the `exit(0)` and leave the erase — every line above it is the part that
/// matters.
struct EraseAndExitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BrowsingStore.shared

    // Traces: on by default.
    @State private var browsingData = true
    @State private var history = true
    @State private var continueWatching = true
    // Things someone chose to keep: off by default.
    @State private var watchLater = false
    @State private var bookmarks = false

    @State private var erasing = false

    private var nothingChosen: Bool {
        !browsingData && !history && !continueWatching && !watchLater && !bookmarks
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Cookies and site data", isOn: $browsingData)
                    Toggle("History and Most Visited", isOn: $history)
                    Toggle("Continue Watching", isOn: $continueWatching)
                } header: {
                    Text("Traces")
                } footer: {
                    Text("Logins, caches, the pages you visited and where you stopped.")
                }

                Section {
                    Toggle("Watch Later", isOn: $watchLater)
                    Toggle("Bookmarks", isOn: $bookmarks)
                } header: {
                    Text("Things you saved")
                } footer: {
                    Text("Off unless you ask — these are lists you built on purpose.")
                }

                Section {
                    Button(role: .destructive) {
                        erasing = true
                        Task { await erase() }
                    } label: {
                        HStack {
                            Spacer()
                            if erasing {
                                ProgressView()
                            } else {
                                Label("Erase and Exit", systemImage: "xmark.octagon.fill")
                            }
                            Spacer()
                        }
                    }
                    .disabled(nothingChosen || erasing)
                } footer: {
                    Text("Panura closes when this finishes. Nothing erased can be recovered.")
                }
            }
            .navigationTitle("Erase data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(erasing)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(erasing)
    }

    private func erase() async {
        // Website data first, and awaited: it is the only one that is
        // asynchronous, and quitting before WebKit has finished writing would
        // leave exactly the cookies this button promised to remove.
        if browsingData { await Self.clearWebsiteData() }
        if history { store.clearHistory() }
        if continueWatching { store.clearWatching() }
        if watchLater { store.clearWatchLater() }
        if bookmarks { store.clearBookmarks() }

        // Every store above writes through UserDefaults, which flushes on its
        // own schedule. `exit(0)` gives it no chance to, so ask for it.
        UserDefaults.standard.synchronize()
        exit(0)
    }

    /// Everything WebKit holds, not the curated subsets Settings offers.
    /// The point of this screen is to leave nothing.
    private static func clearWebsiteData() async {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { cont.resume() }
        }
    }
}
