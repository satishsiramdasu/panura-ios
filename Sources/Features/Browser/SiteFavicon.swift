import SwiftUI

/// The site's own mark, in the leading cell of the browser's address pill.
///
/// Shaped and sized exactly like `PanuraGlyph`, which it replaced there, so the
/// pill's geometry does not move between Home (the app's mark) and the browser
/// (the page's). It carries the same two states that cell has always had: lit
/// while the site panel is open, and marked when a protection is switched off
/// for this site.
///
/// Three things can be drawn, in order: the page's icon, the app's mark while
/// one is being fetched or when the page has none, and the private-browsing
/// tint over either. A page with a broken icon falls back silently — a hole
/// where a mark should be reads as a bug, and the cell is a button besides.
struct SiteFavicon: View {
    var url: URL?
    var active: Bool = false
    var marked: Bool = false
    var tint: Color?
    var label: String
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if active {
                    Circle().fill(PanuraTheme.surfaceContainerHighest)
                }
                mark
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                if marked {
                    Circle()
                        .fill(PanuraTheme.error)
                        .frame(width: 7, height: 7)
                        .offset(x: 9, y: -9)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var mark: some View {
        if let tint {
            // Private browsing recolours the cell rather than showing the
            // site's own colours, because the session is the more important
            // fact while it is on.
            fallbackMark.foregroundStyle(tint)
        } else if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: fallbackMark
                // The app's mark while it loads, not a blank: the cell is 30
                // points of button and an empty one looks broken.
                default: fallbackMark
                }
            }
        } else {
            fallbackMark
        }
    }

    private var fallbackMark: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
    }
}
