import SwiftUI

/// The header's Downloads button (Android 6ebb8db, 50f172f, a1e4f1e, 7630f60).
///
/// At rest, the Downloads glyph. While something downloads, the same glyph at
/// the same size: its tray held still and its arrow looping downward into it,
/// clipped so the arrow never slides over the tray — inside a ring that fills
/// as the download goes, or turns when the size is not known yet. A dot means
/// something finished that has not been looked at.
struct DownloadsHeaderButton: View {
    let action: () -> Void
    @ObservedObject private var store = DownloadStore.shared

    var body: some View {
        Button(action: action) {
            ZStack {
                if store.isDownloading {
                    ring
                    FallingArrow()
                } else {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(PanuraTheme.onSurface)
                        .overlay(alignment: .topTrailing) {
                            if store.unseen {
                                Circle()
                                    .fill(PanuraTheme.accent)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 4, y: -3)
                            }
                        }
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isDownloading ? "Downloads, downloading" : "Downloads")
    }

    @ViewBuilder
    private var ring: some View {
        if let progress = store.runningProgress {
            ZStack {
                Circle().stroke(PanuraTheme.onSurface.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(PanuraTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 34, height: 34)
        } else {
            SpinningRing().frame(width: 34, height: 34)
        }
    }
}

/// The resting glyph cut in two: the tray drawn still, the arrow above it
/// falling in from the top and out into the tray, again and again.
private struct FallingArrow: View {
    @State private var fall = false
    /// Where the tray starts, as a share of the glyph's height.
    private let cut: CGFloat = 0.78

    var body: some View {
        let glyph = Image(systemName: "arrow.down.to.line")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(PanuraTheme.onSurface)
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                // The tray, still.
                glyph.mask(alignment: .top) {
                    Rectangle().frame(height: h * (1 - cut)).offset(y: h * cut)
                }
                // The arrow alone, clipped above the tray before it moves so
                // the tray never rides into view with it.
                glyph
                    .mask(alignment: .top) { Rectangle().frame(height: h * cut) }
                    .offset(y: fall ? h * cut : -h * cut)
                    .mask(alignment: .top) { Rectangle().frame(height: h * cut) }
            }
        }
        .frame(width: 22, height: 22)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { fall = true }
        }
    }
}

private struct SpinningRing: View {
    @State private var turn = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(PanuraTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turn = true }
            }
    }
}
