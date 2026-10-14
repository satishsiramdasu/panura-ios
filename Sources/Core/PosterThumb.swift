import SwiftUI

/// The picture beside a video, wherever one is listed.
///
/// One view for three places — the found-video sheet, the cast screen and the
/// queue — because they show the same thing from different sources: a page's
/// poster arrives as a URL to fetch, a video in the library arrives as an image
/// already in memory, and plenty of streams have neither.
///
/// The fallback is a glyph on the app's own surface rather than a grey box or a
/// broken-image mark: a stream with no artwork is normal, not an error, and a
/// row that looks broken invites a tap to fix it.
struct PosterThumb: View {
    var url: URL?
    /// Tried when `url` fails to load.
    ///
    /// A page can state its artwork twice and disagree with itself: the embedded
    /// player sets MediaSession artwork, which describes the video and so wins,
    /// while the page's own og:image describes the page. The first is the better
    /// answer when it resolves and nothing at all when it does not - some
    /// players name a file that is not served, or a path relative to a frame
    /// this app never loaded. Falling back keeps the picture the page did state.
    var alternate: URL?
    var image: UIImage?
    /// What to draw when there is no picture — a globe for a stream, a film
    /// frame for something in the library.
    var fallback: String = "film"
    var width: CGFloat = 142
    var height: CGFloat = 80
    var corner: CGFloat = 8

    @State private var fellBack = false

    var body: some View {
        Group {
            if let image {
                fitted(Image(uiImage: image))
            } else if let shown = fellBack ? alternate : url {
                RemoteImage(url: shown) { phase in
                    switch phase {
                    case let .success(image):
                        fitted(image)
                    case .failure:
                        if !fellBack, alternate != nil {
                            // Drawn as the glyph for the instant it takes to
                            // ask again, so the row never flashes a broken mark.
                            tile.onAppear { fellBack = true }
                        } else {
                            tile
                        }
                    default:
                        // Empty and failure look the same on purpose: a poster
                        // that never arrives should leave the row as it was, not
                        // announce itself.
                        tile
                    }
                }
            } else {
                tile
            }
        }
        .frame(width: width, height: height)
    }

    /// The whole picture, in its own shape, inside the box.
    ///
    /// Posters are not one shape: a film site publishes a portrait sheet, a
    /// video site a 16:9 still, and plenty publish a square. Filling the box
    /// crops two of the three. It used to fit the picture over a blown-up blur
    /// of itself, and the blur read as the same poster cropped to the box — so
    /// the picture now stands alone, rounded on its own edges, and the box is
    /// only room for it.
    private func fitted(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(PanuraTheme.surfaceVariant)
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: fallback)
            .font(.system(size: min(width, height) * 0.42))
            .foregroundStyle(PanuraTheme.onSurfaceVariant)
    }
}
