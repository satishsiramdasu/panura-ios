import SwiftUI
import WebKit

/// "Clear Data" — a centred dialog, from Home's third tile.
///
/// A checklist rather than one destructive button, because the things it can
/// remove are not equally regrettable. History, the visit tally, resume points
/// and the cache are traces; Bookmarks and Watch Later are lists someone built
/// on purpose, and cookies are every login they have. The first four default
/// on, the last three have to be asked for.
///
/// Centred, not a sheet. A sheet slides up from the far end of the screen and
/// reads as a place you have gone; this is a question about the button you just
/// pressed, and it should arrive where you are looking.
struct ClearDataDialog: View {
    @Binding var isPresented: Bool
    var onCleared: (String) -> Void = { _ in }

    @ObservedObject private var store = BrowsingStore.shared

    // Traces: on.
    @State private var browsingHistory = true
    @State private var watchHistory = true
    @State private var mostVisited = true
    @State private var cache = true
    // Kept on purpose: off.
    @State private var watchLater = false
    @State private var bookmarks = false
    @State private var cookies = false

    @State private var working = false

    private var nothingChosen: Bool {
        !browsingHistory && !watchHistory && !mostVisited
            && !cache && !watchLater && !bookmarks && !cookies
    }

    var body: some View {
        ZStack {
            // Tapping away is the same as Cancel, which is what people expect of
            // anything that dims the screen behind it.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { if !working { close() } }

            dialog
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    private var dialog: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clear Data").font(.headline)
                Text("Choose what to remove. This cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // Scrolls rather than grows: seven rows plus two buttons is taller
            // than a small phone in landscape, and a dialog that runs off the
            // screen loses its own actions.
            ScrollView {
                VStack(spacing: 0) {
                    row("Browsing history", isOn: $browsingHistory)
                    row("Watch history", isOn: $watchHistory)
                    row("Most visited", isOn: $mostVisited)
                    row("Browser cache", isOn: $cache)
                    row("Watch Later", isOn: $watchLater)
                    row("Bookmarks", isOn: $bookmarks)
                    row("Browser cookies", isOn: $cookies)
                }
            }
            .frame(maxHeight: 320)

            Divider()

            HStack(spacing: 10) {
                Button { close() } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(PanuraTheme.surfaceVariant, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(working)

                Button { clear() } label: {
                    Group {
                        if working {
                            ProgressView().tint(.white)
                        } else {
                            Text("Clear").font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        Capsule().fill(nothingChosen ? Color.red.opacity(0.35) : Color.red)
                    )
                }
                .buttonStyle(.plain)
                .disabled(nothingChosen || working)
            }
            .padding(16)
        }
        .background(PanuraTheme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 20))
    }

    /// A row, not a `Toggle`: the whole row is the target, and a checkbox says
    /// "one of several" where a switch says "a setting that stays".
    private func row(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn.wrappedValue ? PanuraTheme.accent : PanuraTheme.onSurfaceVariant)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { isPresented = false }
    }

    private func clear() {
        working = true
        Task {
            // The WebKit stores are the only asynchronous part, and they are
            // taken first so the rest cannot report success before they finish.
            var types: Set<String> = []
            if cache {
                types.formUnion([
                    WKWebsiteDataTypeDiskCache,
                    WKWebsiteDataTypeMemoryCache,
                    WKWebsiteDataTypeOfflineWebApplicationCache,
                ])
            }
            if cookies {
                // Local storage goes with them: a site's session is as often in
                // one as the other, and clearing half leaves a login that half
                // works.
                types.formUnion([
                    WKWebsiteDataTypeCookies,
                    WKWebsiteDataTypeLocalStorage,
                    WKWebsiteDataTypeSessionStorage,
                    WKWebsiteDataTypeIndexedDBDatabases,
                ])
            }
            if !types.isEmpty { await Self.removeWebsiteData(types) }

            if browsingHistory { store.clearBrowsingHistory() }
            if mostVisited { store.clearMostVisited() }
            if watchHistory { store.clearWatching() }
            if watchLater { store.clearWatchLater() }
            if bookmarks { store.clearBookmarks() }

            working = false
            isPresented = false
            onCleared("Data cleared")
        }
    }

    private static func removeWebsiteData(_ types: Set<String>) async {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().removeData(
                ofTypes: types, modifiedSince: .distantPast
            ) { cont.resume() }
        }
    }
}
