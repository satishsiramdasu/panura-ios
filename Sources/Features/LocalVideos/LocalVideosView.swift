import SwiftUI
import Photos
import AVFoundation

/// Lists videos from the Photos library — the iOS equivalent of Android's
/// MediaStore-backed local video picker.
struct LocalVideosView: View {
    @StateObject private var model = LocalVideosModel()
    @State private var playItem: MediaItem?
    @State private var playIndex = 0

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .needsPermission:
                    permissionPrompt
                case .empty:
                    ContentUnavailableViewCompat(
                        title: "No videos", systemImage: "film",
                        description: "Videos in your library will show up here."
                    )
                case .loaded(let items):
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                Button { play(item, at: idx) } label: { VideoCell(item: item) }
                            }
                        }
                        .padding(12)
                    }
                case .loading:
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .top) { PanuraHeader("Videos") }
            .navigationBarHidden(true)
        }
        .task { await model.load() }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0, playlist: localPlaylist()) }
    }

    /// Playlist over the loaded library so the player's next/previous can advance.
    /// URLs resolve lazily — only the item being played is resolved.
    private func localPlaylist() -> PlayerPlaylist? {
        guard case .loaded(let items) = model.state, items.count > 1 else { return nil }
        return PlayerPlaylist(count: items.count, startIndex: playIndex) { i in
            guard i >= 0, i < items.count,
                  let url = await model.resolveURL(for: items[i]) else { return nil }
            return MediaItem(title: items[i].title, url: url, isLocal: true)
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
            Text("Allow access to your videos").font(.headline)
            Button("Grant Access") { Task { await model.requestAccess() } }
                .buttonStyle(.borderedProminent)
                .tint(PanuraTheme.accent)
        }
    }

    private func play(_ asset: LocalVideoAsset, at index: Int) {
        Task {
            if let url = await model.resolveURL(for: asset) {
                playIndex = index
                playItem = MediaItem(title: asset.title, url: url, isLocal: true)
            }
        }
    }
}

private struct VideoCell: View {
    let item: LocalVideoAsset
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                }
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.title).font(.caption).lineLimit(1)
        }
    }
}

/// Back-compat wrapper so this compiles on iOS 15 (ContentUnavailableView is iOS 17+).
private struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
