import SwiftUI

/// Paste-a-URL playback — mirrors the Android "Stream" tab.
struct StreamView: View {
    @State private var urlText = ""
    @State private var playItem: MediaItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Paste video / stream URL (.m3u8, .mp4, .mpd)", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))

                Button("Play") { play() }
                    .buttonStyle(.borderedProminent)
                    .tint(PanuraTheme.accent)
                    .disabled(URL(string: urlText) == nil)

                Spacer()
            }
            .padding(16)
            .navigationTitle("Stream")
        }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0) }
    }

    private func play() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { return }
        playItem = MediaItem(title: "Stream", url: url)
    }
}
