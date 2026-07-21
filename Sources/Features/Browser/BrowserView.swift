import SwiftUI

struct BrowserView: View {
    @StateObject private var model = BrowserModel()
    @State private var addressText = ""
    @State private var playItem: MediaItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                WebViewContainer(model: model)
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                if !model.foundVideos.isEmpty {
                    foundVideosBar
                }
            }
        }
        .fullScreenCover(item: $playItem) { PlayerView(item: $0) }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search or enter address", text: $addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .onSubmit { model.load(addressText) }
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PanuraTheme.accentSoft, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: model.currentURL) { url in
            if let url { addressText = url.absoluteString }
        }
    }

    private var foundVideosBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.foundVideos) { v in
                    Button {
                        playItem = MediaItem(
                            title: v.title, url: v.url, headers: v.headers
                        )
                    } label: {
                        Label(v.title.isEmpty ? "Play video" : v.title,
                              systemImage: "play.circle.fill")
                            .lineLimit(1)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(PanuraTheme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }
}
