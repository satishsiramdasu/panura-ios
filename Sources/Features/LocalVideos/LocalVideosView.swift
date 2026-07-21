import SwiftUI
import Photos
import AVFoundation

/// Lists videos from the Photos library — the iOS equivalent of Android's
/// MediaStore-backed local video picker.
struct LocalVideosView: View {
    @StateObject private var model = LocalVideosModel()
    @State private var playItem: MediaItem?

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
                            ForEach(items) { item in
                                Button { play(item) } label: { VideoCell(item: item) }
                            }
                        }
                        .padding(12)
                    }
                case .loading:
                    ProgressView()
                }
            }
            .navigationTitle("Local Videos")
        }
        .task { await model.load() }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0) }
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

    private func play(_ asset: LocalVideoAsset) {
        Task {
            if let url = await model.resolveURL(for: asset) {
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
