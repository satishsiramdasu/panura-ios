import SwiftUI

/// The strip above the app bar naming what is still playing after the player
/// screen has gone — Picture in Picture, or a TV.
///
/// It exists because leaving the player used to mean losing the video. PiP now
/// takes the picture and the screen comes down, so something has to say where
/// the video went and offer the way back; the same is true of a cast, which
/// until now was only visible from the screen that started it.
///
/// Deliberately not a mini *player*: no second video surface, no scrubber. The
/// picture is already somewhere — floating, or on the TV — and drawing it twice
/// costs a decoder and buys nothing. Title, state, play/pause, close.
struct NowPlayingBar: View {
    let title: String
    /// "Picture in Picture", or the TV's name.
    let where_: String
    let isPlaying: Bool
    let onTap: () -> Void
    let onPlayPause: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pip.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(PanuraTheme.accentSoft))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(where_)
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

            Button(action: onClose) {
                Image(systemName: "xmark")
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
