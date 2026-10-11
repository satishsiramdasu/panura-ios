import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Home's "pick a video and play it" card.
///
/// Sits where the cast card used to. Casting is something you reach for *after*
/// you have chosen something to watch, which made it the last card on a screen
/// people open to start watching; picking a video is the start of that, so it
/// goes above the destinations rather than below them.
///
/// `PHPickerViewController` runs out of process and needs **no photo library
/// permission at all** — it hands back only what the user pointed at. So this
/// works for someone who refused the Videos tab, which is most of the point of
/// having it: one tap, one video, no setup and no dialog.
struct PickVideoCard: View {
    @State private var picking = false
    @State private var preparing = false

    var body: some View {
        Button { picking = true } label: { card }
            .buttonStyle(.plain)
            .disabled(preparing)
            .accessibilityLabel("Pick a video to play")
            .sheet(isPresented: $picking) {
                VideoPicker(onPick: prepare)
                    .ignoresSafeArea()
            }
    }

    private var card: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(PanuraTheme.accent)
                .frame(width: 42, height: 42)
                .background(PanuraTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("Pick a video")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(preparing ? "Getting it ready…" : "Play one from this phone, right now")
                    .font(.caption)
                    .foregroundStyle(PanuraTheme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if preparing {
                ProgressView()
                    .tint(PanuraTheme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                Text("Browse")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PanuraTheme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(PanuraTheme.accent, in: Capsule())
            }
        }
        .padding(12)
        .background(PanuraTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Both halves of this — the picker and the copy-then-play — are shared
    /// with the Videos tab's permission screens. See `VideoPicker`.
    private func prepare(_ provider: NSItemProvider) {
        preparing = true
        PickedVideo.play(provider) { _ in preparing = false }
    }
}
