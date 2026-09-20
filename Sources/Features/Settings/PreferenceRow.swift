import SwiftUI

/// Android's `ClickablePreferenceItem`, which every settings screen there is
/// built from: an accent glyph, a title, and a line of description saying what
/// the screen behind it holds.
///
/// The description is not decoration — it is what makes a list of six words
/// navigable without opening all six. Every row that leads somewhere carries
/// one, exactly as on Android.
struct PreferenceRow<Destination: View>: View {
    let title: String
    let description: String
    let icon: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            PreferenceLabel(title: title, description: description, icon: icon)
        }
    }
}

/// The same row without a destination — for the ones that act rather than
/// navigate.
struct PreferenceButton: View {
    let title: String
    let description: String
    let icon: String
    var tint: Color = PanuraTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PreferenceLabel(title: title, description: description, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

struct PreferenceLabel: View {
    let title: String
    let description: String
    let icon: String
    var tint: Color = PanuraTheme.accent

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(PanuraTheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A toggle wearing the same glyph + description as the rows around it, so a
/// switch and a link read as one list rather than two.
struct PreferenceToggle: View {
    let title: String
    let description: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            PreferenceLabel(title: title, description: description, icon: icon)
        }
    }
}

/// The same row, navigating by value instead of by view.
///
/// A view-based `NavigationLink` pushes a screen the stack's `path` knows
/// nothing about, so setting the path cannot replace it — which is how opening
/// Browser settings from the browser used to land on whichever settings screen
/// had been left open. Every row on the Settings root goes through this, so the
/// path is the whole truth about where the stack is.
struct PreferenceLink<Value: Hashable>: View {
    let title: String
    let description: String
    let icon: String
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            PreferenceLabel(title: title, description: description, icon: icon)
        }
    }
}
