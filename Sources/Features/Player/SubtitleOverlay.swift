import SwiftUI

/// Subtitle text drawn over the video, in the look set in Settings → Subtitles.
///
/// For engines that do not draw a file's subtitles into the picture — the Apple
/// player, for files sniffed from the page. VLC renders its own and publishes
/// nothing here.
///
/// Reads the settings itself rather than being handed them, so a change in the
/// player's subtitle sheet shows on the very next frame with no reopen.
struct SubtitleOverlay: View {
    let text: String?
    /// Extra space underneath while the controls are showing, so a line is
    /// never drawn beneath the bottom bar.
    let lift: CGFloat

    @AppStorage("subtitle_size") private var size = 24
    @AppStorage("subtitle_color") private var color = 0xFFFFFF
    @AppStorage("subtitle_background") private var background = false
    @AppStorage("subtitle_bold") private var bold = false
    @AppStorage("subtitle_outline") private var outline = 4
    @AppStorage("subtitle_font") private var font = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let text, !text.isEmpty {
                line(text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.bottom, 20 + lift)
        .animation(.easeOut(duration: 0.2), value: lift)
        .allowsHitTesting(false)
    }

    private func line(_ text: String) -> some View {
        // The outline is four hard shadows, one per direction — SwiftUI text has
        // no stroke. The steps match VLC's (None, Thin, Medium, Thick) closely
        // enough that switching engines does not change how a subtitle reads.
        let edge = CGFloat(outline) * 0.35
        let outlineColor: Color = edge > 0 ? .black : .clear
        return Text(text)
            .font(typeface)
            .fontWeight(bold ? .bold : .semibold)
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .shadow(color: outlineColor, radius: 0, x: edge, y: 0)
            .shadow(color: outlineColor, radius: 0, x: -edge, y: 0)
            .shadow(color: outlineColor, radius: 0, x: 0, y: edge)
            .shadow(color: outlineColor, radius: 0, x: 0, y: -edge)
            .padding(.horizontal, background ? 8 : 0)
            .padding(.vertical, background ? 3 : 0)
            .background(
                background ? Color.black.opacity(0.8) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
    }

    /// libVLC's size is in pixels of its own renderer; three-quarters of it in
    /// points lands Medium at the size a phone's own captions use.
    private var pointSize: CGFloat { CGFloat(size) * 0.75 }

    private var typeface: Font {
        font.isEmpty ? .system(size: pointSize) : .custom(font, size: pointSize)
    }

    private var textColor: Color {
        Color(
            red: Double((color >> 16) & 0xFF) / 255,
            green: Double((color >> 8) & 0xFF) / 255,
            blue: Double(color & 0xFF) / 255
        )
    }
}
