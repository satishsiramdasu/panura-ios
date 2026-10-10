import SwiftUI

/// The progress bar, cut into chapters.
///
/// A programme that carries chapters is exactly the one people skip around in
/// — past the recap, past the titles, out before the credits — and a single
/// unbroken track tells them nothing about where any of that is. Drawn as
/// separate pieces with a gap between, the bar answers it at a glance, and
/// "drag until the picture changes" becomes "drop the thumb in that piece".
/// It is what YouTube does, for the reason YouTube does it.
///
/// Hand-drawn rather than layered on `Slider`, because none of `Slider`'s parts
/// are reachable: its track is one piece, its thumb is Apple's, and neither
/// takes a shape. A stream with no chapters draws one piece and is a plain bar
/// again, so there is only ever this one control.
struct ChapterScrubber: View {
    /// Where the thumb is, 0...1.
    let fraction: Double
    /// Chapter starts as fractions of the whole. Zero and one are implied, so
    /// an empty list is a bar with no cuts in it.
    let cuts: [Double]
    /// Whether a finger is on it. The bar thickens while there is.
    let active: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    /// The gap between two pieces. Wide enough to read as a cut at a glance,
    /// narrow enough that twenty chapters do not eat the bar.
    private static let gap: CGFloat = 3
    /// The row's height — fixed, and much taller than the bar it draws, so the
    /// touch target is a thumb's width rather than a four-point line.
    private static let row: CGFloat = 30

    private var barHeight: CGFloat { active ? 7 : 4 }
    private var thumbSize: CGFloat { active ? 15 : 12 }

    var body: some View {
        GeometryReader { geo in
            let track = Track(cuts: cuts, width: geo.size.width, gap: Self.gap)
            ZStack(alignment: .leading) {
                pieces(track)
                Circle()
                    .fill(PanuraTheme.accent)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    // Placed through the same mapping as the fill, not on a
                    // bare `fraction * width`: with gaps in the track the two
                    // disagree by the width of every gap before the thumb, and
                    // a thumb that floats off the end of its own fill is the
                    // kind of wrong people see without being able to name.
                    .offset(x: track.x(of: clamp(fraction)) - thumbSize / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                // Zero minimum distance, so a tap anywhere on the row seeks
                // there — the same as dragging to it, and the thing everybody
                // tries first.
                DragGesture(minimumDistance: 0)
                    .onChanged { onScrub(track.fraction(at: $0.location.x)) }
                    .onEnded { onCommit(track.fraction(at: $0.location.x)) }
            )
        }
        .frame(height: Self.row)
        .animation(.easeOut(duration: 0.15), value: active)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((clamp(fraction) * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            onCommit(clamp(fraction + (direction == .increment ? 0.02 : -0.02)))
        }
    }

    private func pieces(_ track: Track) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(track.segments) { segment in
                Capsule()
                    .fill(Color.white.opacity(0.26))
                    .frame(width: segment.width, height: barHeight)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(PanuraTheme.accent)
                            .frame(width: segment.width * filled(segment))
                    }
            }
        }
    }

    /// How much of one piece is behind the thumb.
    private func filled(_ segment: Track.Segment) -> CGFloat {
        let span = max(0.0001, segment.end - segment.start)
        return CGFloat(min(1, max(0, (clamp(fraction) - segment.start) / span)))
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// The arithmetic of a bar with gaps in it.
///
/// Kept apart from the view because it is the only part that can be wrong in a
/// way nobody sees until they use it: the gaps take real width, so a fraction
/// is not a position and a position is not a fraction, and the two mappings
/// have to be each other's inverse or the thumb lands where the finger is not.
private struct Track {
    struct Segment: Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let width: CGFloat
    }

    let segments: [Segment]
    private let gap: CGFloat

    init(cuts: [Double], width: CGFloat, gap: CGFloat) {
        self.gap = gap
        // Zero and one are the ends of the bar, not cuts, and a chapter
        // starting at either would otherwise produce a segment of no width.
        var edges = cuts.filter { $0 > 0.001 && $0 < 0.999 }.sorted()
        edges.insert(0, at: 0)
        edges.append(1)

        let usable = max(0, width - gap * CGFloat(edges.count - 2))
        segments = (0..<(edges.count - 1)).map { index in
            Segment(
                id: index,
                start: edges[index],
                end: edges[index + 1],
                width: max(1, CGFloat(edges[index + 1] - edges[index]) * usable)
            )
        }
    }

    /// Where along the bar a fraction sits.
    func x(of fraction: Double) -> CGFloat {
        var offset: CGFloat = 0
        for segment in segments {
            let span = max(0.0001, segment.end - segment.start)
            if fraction <= segment.end || segment.id == segments.count - 1 {
                let within = min(1, max(0, (fraction - segment.start) / span))
                return offset + segment.width * CGFloat(within)
            }
            offset += segment.width + gap
        }
        return offset
    }

    /// What fraction a touch at this position means. A touch landing in a gap
    /// is rounded into the piece it is nearest, which is what the arithmetic
    /// does on its own — there is nothing in a gap to aim at.
    func fraction(at x: CGFloat) -> Double {
        var remaining = max(0, x)
        for segment in segments {
            if remaining <= segment.width || segment.id == segments.count - 1 {
                let within = min(1, max(0, remaining / segment.width))
                return segment.start + Double(within) * (segment.end - segment.start)
            }
            remaining -= segment.width + gap
        }
        return 1
    }
}
