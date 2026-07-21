import SwiftUI
import AVKit

/// Full-screen player built on AVPlayerViewController — Apple's native player.
/// Gives scrubbing, subtitle/audio-track selection, Picture-in-Picture, AirPlay,
/// playback speed, and fullscreen for free. Plays HLS + MP4; custom request
/// headers (gated streams) attach via AVURLAsset options.
struct PlayerView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AVPlayerControllerView(item: item)
            .ignoresSafeArea()
            .background(.black)
    }
}

private struct AVPlayerControllerView: UIViewControllerRepresentable {
    let item: MediaItem

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        configureAudioSession()

        let asset: AVURLAsset = item.headers.isEmpty
            ? AVURLAsset(url: item.url)
            : AVURLAsset(url: item.url, options: ["AVURLAssetHTTPHeaderFieldsKey": item.headers])

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.allowsExternalPlayback = true // AirPlay

        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
