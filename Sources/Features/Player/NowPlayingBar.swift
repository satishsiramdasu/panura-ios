import SwiftUI

/// The strip above the app bar naming the television that has the video.
///
/// It exists because casting is invisible. The video is on a TV, the phone
/// shows nothing at all, and walking away from the screen that started the cast
/// left no way to pause it or even to see that it was running.
///
/// It briefly covered Picture in Picture too, and should not have: iOS floats
/// its own window whenever PiP runs, with pause, close and restore on the
/// window itself, so the bar could never appear except underneath a control
/// that was already better placed. Written generically anyway — the icon and
/// every label are parameters — because the next thing that plays somewhere
/// else will want the same strip.
///
/// Deliberately not a mini *player*: no video surface, no scrubber. The picture
/// is already on the TV, and drawing it twice costs a decoder and buys nothing.
/// Title, where, time left, play/pause, close.
struct NowPlayingBar: View {
    /// The glyph that says where the video went.
    var icon: String = "tv.fill"
    let title: String
    /// "Picture in Picture", or the TV's name.
    let where_: String
    /// "12:04 left" — what is left of the video, or empty when unknown (a live
    /// stream has no end). Beside the state rather than under it: the bar is
    /// one line tall and the two facts are read together.
    let timeLeft: String
    let isPlaying: Bool
    let onTap: () -> Void
    let onPlayPause: () -> Void
    /// Stops what is on the television. Not a disconnect: the TV stays linked,
    /// ready for the next video, because "I have finished this one" and "I have
    /// finished with the television" are different intentions and an X reads as
    /// the second.
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(PanuraTheme.accentSoft))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(where_)
                    if !timeLeft.isEmpty {
                        Text("·")
                        Text(timeLeft).monospacedDigit()
                    }
                }
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(PanuraTheme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 6)
        .background(PanuraTheme.surfaceContainerHigh)
        // The whole strip returns to the player, except where a button already
        // claimed the tap.
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }
}
