import SwiftUI

/// The bar across the bottom of a picture saying how far through it you are.
///
/// Drawn on the artwork rather than beside it, because the artwork is what the
/// eye lands on and a strip under it is read without being looked at — the
/// convention every video app has settled on, and the reason it works is that
/// it costs the layout nothing. A thing never started draws nothing at all: a
/// grid where every tile carries an empty bar is a grid that has taught you to
/// stop seeing bars.
struct WatchStrip: View {
    let state: WatchState
    var height: CGFloat = 3

    var body: some View {
        switch state {
        case .unseen:
            EmptyView()
        case .finished:
            Rectangle()
                .fill(PanuraTheme.accent)
                .frame(height: height)
        case .partial(let fraction):
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.45))
                    Rectangle()
                        .fill(PanuraTheme.accent)
                        .frame(width: geo.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: height)
        }
    }
}
