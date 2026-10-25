import SwiftUI

/// The header's Downloads button, drawn the way Android's `ShellActionButton` is.
///
/// At rest, the Download glyph. While something downloads, the same glyph at
/// the same size: its tray held still and its arrow looping down through the
/// ring — in from the top, out into the tray, and in again — with the ring
/// filling as the download goes, or turning when the size is not known yet. A
/// dot means something finished that has not been looked at.
///
/// The glyph is Material's rounded Download, in its own 24-unit grid, cut at
/// 17/24 as Android cuts it. An SF Symbol cannot be cut that way: its arrow and
/// tray do not sit on the same lines, so the fall broke the shaft into pieces.
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
                    DownloadGlyph()
                        .overlay(alignment: .topTrailing) {
                            if store.unseen {
                                Circle()
                                    .fill(PanuraTheme.accent)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 3, y: -3)
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
            .frame(width: 36, height: 36)
        } else {
            SpinningRing().frame(width: 36, height: 36)
        }
    }
}

// MARK: - the glyph

/// Material Rounded "Download", split into its two parts, on a 24-unit grid.
private enum DownloadShape {
    static func arrow(_ r: CGRect) -> Path {
        let s = r.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        path.move(to: p(16.59, 9))
        path.addLine(to: p(15, 9))
        path.addLine(to: p(15, 4))
        path.addCurve(to: p(14, 3), control1: p(15, 3.45), control2: p(14.55, 3))
        path.addLine(to: p(10, 3))
        path.addCurve(to: p(9, 4), control1: p(9.45, 3), control2: p(9, 3.45))
        path.addLine(to: p(9, 9))
        path.addLine(to: p(7.41, 9))
        path.addCurve(to: p(6.7, 10.71), control1: p(6.52, 9), control2: p(6.07, 10.08))
        path.addLine(to: p(11.29, 15.3))
        path.addCurve(to: p(12.7, 15.3), control1: p(11.68, 15.69), control2: p(12.31, 15.69))
        path.addLine(to: p(17.29, 10.71))
        path.addCurve(to: p(16.59, 9), control1: p(17.92, 10.08), control2: p(17.48, 9))
        path.closeSubpath()
        return path
    }

    static func tray(_ r: CGRect) -> Path {
        let s = r.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        path.move(to: p(5, 19))
        path.addCurve(to: p(6, 20), control1: p(5, 19.55), control2: p(5.45, 20))
        path.addLine(to: p(18, 20))
        path.addCurve(to: p(19, 19), control1: p(18.55, 20), control2: p(19, 19.55))
        path.addCurve(to: p(18, 18), control1: p(19, 18.45), control2: p(18.55, 18))
        path.addLine(to: p(6, 18))
        path.addCurve(to: p(5, 19), control1: p(5.45, 18), control2: p(5, 18.45))
        path.closeSubpath()
        return path
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path { DownloadShape.arrow(rect) }
}

private struct TrayShape: Shape {
    func path(in rect: CGRect) -> Path { DownloadShape.tray(rect) }
}

/// The resting glyph: 24 points, in the header's ink.
private struct DownloadGlyph: View {
    var body: some View {
        ZStack {
            ArrowShape().fill(PanuraTheme.onSurface)
            TrayShape().fill(PanuraTheme.onSurface)
        }
        .frame(width: 24, height: 24)
    }
}

/// The glyph cut at 17/24: the tray drawn still, the arrow above it looping
/// down. Android's animation to the number — 1100 ms, linear, restarting, the
/// arrow travelling from one cut-height above to one cut-height below.
private struct FallingArrow: View {
    @State private var fall = false
    private let size: CGFloat = 24
    private let cut: CGFloat = 17.0 / 24.0

    var body: some View {
        let window = size * cut
        ZStack(alignment: .top) {
            // The tray, still: the lower part of the glyph.
            TrayShape()
                .fill(PanuraTheme.onSurface)
                .frame(width: size, height: size)
            // The arrow alone, cut to the window above the tray before it moves,
            // and cut again after, so it vanishes into the tray rather than
            // sliding across it.
            ArrowShape()
                .fill(PanuraTheme.onSurface)
                .frame(width: size, height: size)
                .frame(width: size, height: window, alignment: .top)
                .clipped()
                .offset(y: fall ? window : -window)
                .frame(width: size, height: window, alignment: .top)
                .clipped()
                .frame(width: size, height: size, alignment: .top)
        }
        .frame(width: size, height: size)
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
