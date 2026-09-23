import SwiftUI

/// The pages and videos set aside for later.
///
/// A screen rather than a sheet, because it holds two kinds of thing and both
/// of them lead somewhere: a web page opens in the browser, a library video
/// plays. A sheet that dismisses itself to hand you to another screen is a
/// detour with a step in it.
///
/// What it stores is deliberately thin. A web entry keeps the PAGE address,
/// never the stream found on it: detected stream URLs are signed and die within
/// hours, so opening one tomorrow means detecting it again. A library entry
/// keeps the asset's identifier, which outlives any file path Photos hands out.
struct WatchLaterView: View {
    /// Opens a saved page in the browser.
    var onOpenBrowser: (String) -> Void

    @ObservedObject private var store = BrowsingStore.shared
    @State private var opening: String?

    var body: some View {
        Group {
            if store.watchLater.isEmpty { empty } else { list }
        }
        .background(PanuraTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            PanuraHeader {
                HStack(spacing: 0) {
                    Text("Watch Later")
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .padding(.leading, 4)
                    Spacer(minLength: 8)
                    if !store.watchLater.isEmpty {
                        // A bin, not three dots. Three dots promise a menu of
                        // things to choose between, and there is only ever one
                        // thing here — a button that says what it does is not
                        // improved by hiding it behind a glyph that does not.
                        //
                        // Still a menu underneath, so the one thing is asked
                        // before it is done, and asked next to the button
                        // rather than in the middle of the screen.
                        Menu {
                            Section("Everything here is removed. Nothing is deleted from the phone.") {
                                Button(role: .destructive) {
                                    store.clearWatchLater()
                                } label: { Label("Clear Watch Later", systemImage: "trash") }
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Clear Watch Later")
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.watchLater) { entry in
                Button { open(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
                    .listRowBackground(PanuraTheme.background)
            }
            .onDelete { offsets in
                // By URL, not by index: the store filters on it, and removing
                // one row shifts every index after it.
                for url in offsets.map({ store.watchLater[$0].url }) {
                    store.removeWatchLater(url: url)
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(_ entry: SiteEntry) -> some View {
        HStack(spacing: 12) {
            if entry.isLocal == true {
                LibraryThumb(localIdentifier: entry.url, width: 142, height: 80, corner: 8)
            } else {
                PosterThumb(
                    url: entry.poster.flatMap(URL.init(string:)),
                    alternate: entry.posterAlt.flatMap(URL.init(string:)),
                    fallback: "globe",
                    width: 142, height: 80, corner: 8
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(entry.isLocal == true ? "On this phone" : entry.host)
                    .font(.caption2)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if opening == entry.url {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// A page goes to the browser; a library video plays where it is.
    ///
    /// The identifier is resolved to a file at the moment it is asked for
    /// rather than when it was saved — an iCloud video may not have been on the
    /// phone at all then, and a path Photos handed out weeks ago is not one it
    /// still honours.
    private func open(_ entry: SiteEntry) {
        guard entry.isLocal == true else {
            onOpenBrowser(entry.url)
            return
        }
        opening = entry.url
        Task {
            defer { opening = nil }
            guard let url = await LocalVideosModel.resolveURL(localIdentifier: entry.url)
            else { return }
            PlaybackSession.shared.play(
                MediaItem(title: entry.title, url: url, isLocal: true)
            )
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 34))
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            Text("Nothing saved yet")
                .font(.subheadline.weight(.semibold))
            Text("""
            Press the clock when Panura finds a video, or hold a video in \
            your library, to keep it for later.
            """)
                .font(.caption)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A library video's own frame, fetched from Photos when the row appears.
///
/// Nothing about the picture is stored: the entry keeps the identifier, and a
/// `UIImage` has no business in UserDefaults. Photos is also the only thing that
/// knows what the video looks like now — it may have been edited since it was
/// set aside, and an iCloud video may not have been on the phone at all.
private struct LibraryThumb: View {
    let localIdentifier: String
    let width: CGFloat
    let height: CGFloat
    let corner: CGFloat

    @State private var image: UIImage?

    var body: some View {
        PosterThumb(
            image: image, fallback: "film",
            width: width, height: height, corner: corner
        )
        .task(id: localIdentifier) {
            guard image == nil else { return }
            image = await LocalVideosModel.thumbnail(
                localIdentifier: localIdentifier,
                // Twice the drawn size, so it is not soft on a 3x screen.
                size: CGSize(width: width * 3, height: height * 3)
            )
        }
    }
}
