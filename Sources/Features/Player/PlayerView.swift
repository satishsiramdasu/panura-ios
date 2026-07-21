import SwiftUI
import AVKit

/// Full-screen player. iOS plays HLS (.m3u8) and MP4 natively via AVPlayer,
/// replacing Android's Media3/ExoPlayer. Custom request headers (for gated
/// streams) are attached via AVURLAsset options.
struct PlayerView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear(perform: buildPlayer)
        .onDisappear { player?.pause() }
    }

    private func buildPlayer() {
        let asset: AVURLAsset
        if item.headers.isEmpty {
            asset = AVURLAsset(url: item.url)
        } else {
            asset = AVURLAsset(
                url: item.url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": item.headers]
            )
        }
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
    }
}
