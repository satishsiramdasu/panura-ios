import SwiftUI

/// The audio and subtitle options, as a card floating over the picture rather
/// than a sheet covering it.
///
/// They were `.sheet`s with `presentationDetents([.medium, .large])`, which
/// reads fine in portrait and not at all in landscape — where this player
/// mostly lives. A sheet in compact height ignores its detents and takes the
/// whole screen, so choosing an audio track meant losing the video entirely,
/// while sleep, speed and quality (plain `Menu`s) never did. This is the same
/// bargain those menus make: the picture stays up, and the choice happens over
/// it.
///
/// Sized against the player's own bounds rather than the safe area, because in
/// landscape it has to stay clear of the notch on one side and the home
/// indicator on the other.
struct PlayerOptionsPanel<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: landscape ? .bottomTrailing : .bottom) {
                // Dim, not black: the point of the whole exercise is that the
                // video is still there. It also catches the tap that closes.
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                card
                    .frame(
                        maxWidth: landscape ? 380 : .infinity,
                        maxHeight: geo.size.height * (landscape ? 0.92 : 0.62)
                    )
                    .padding(landscape ? 12 : 10)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            // The scroll view takes the height it needs and no more, so a panel
            // with two tracks in it is two rows tall instead of a half-empty
            // card.
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PanuraTheme.surfaceContainer.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.08))
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }
}

// MARK: - the rows these panels are built from

/// A small uppercase label above a group. Sections, without a `List`'s chrome.
struct PanelHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

/// A track, or anything else chosen from a list of one.
struct PanelChoiceRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(PanuraTheme.accent)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Label on the left, minus / value / plus on the right — the delay controls.
struct PanelStepperRow: View {
    let title: String
    let value: String
    /// Ahead of `change` so the trailing closure at every call site binds to the
    /// closure and not to this.
    var step = 50
    let change: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.callout).foregroundStyle(.white)
            Spacer(minLength: 8)
            Button { change(-step) } label: { stepGlyph("minus") }
                .buttonStyle(.plain)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 62)
                .multilineTextAlignment(.center)
            Button { change(step) } label: { stepGlyph("plus") }
                .buttonStyle(.plain)
        }
        .padding(.vertical, 7)
    }

    private func stepGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(.white.opacity(0.12)))
    }
}

/// A switch, in the panel's own idiom rather than a full-width `Toggle` row.
struct PanelToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.callout).foregroundStyle(.white)
        }
        .tint(PanuraTheme.accent)
        .padding(.vertical, 3)
    }
}

/// The advanced half of the subtitle panel: shut until asked for.
///
/// Folded because of what the two halves are for. Turning subtitles on, or
/// switching to the other language track, is what people open this for, and it
/// was below a screenful of appearance controls. Size, colour and background are
/// set once and then left alone for months.
struct PanelDisclosure<Content: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 0) { content }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// A hairline between groups. `Divider()` in a dark overlay is nearly black.
struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 1)
    }
}
