import SwiftUI

/// The app's one header, on every screen — port of Android's `PanuraTopAppBar`
/// and the Home/browser address bars, which are all the same 52pt row:
///
///     [ app glyph ] [ title, or an address pill ] [ cast ]
///
/// Written once and used everywhere for the reason Android gives: a screen that
/// styles its own header makes switching destinations look like leaving the app.
/// The glyph and the cast control hold the same pixel on every screen, so only
/// the middle changes as you move.
///
/// The glyph is an SF Symbol rather than the app icon: iOS ships the icon only
/// as an `AppIcon` asset, which cannot be drawn inside the app, and adding a
/// second copy of the artwork to the bundle to fake it is not worth the bytes.
struct PanuraHeader<Content: View>: View {
    /// Tapping the glyph goes Home, as it does on Android's browser. nil leaves
    /// it decorative, which is what every screen that IS a destination wants.
    var onTapGlyph: (() -> Void)?
    @ViewBuilder var content: Content

    static var height: CGFloat { 52 }

    var body: some View {
        HStack(spacing: 4) {
            glyph
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            CastToolbarButton()
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(PanuraTheme.surfaceContainer)
    }

    @ViewBuilder
    private var glyph: some View {
        let icon = Image(systemName: "play.rectangle.fill")
            .font(.system(size: 24))
            .foregroundStyle(PanuraTheme.accent)
            .frame(width: 44, height: 44)
        if let onTapGlyph {
            Button(action: onTapGlyph) { icon }
                .buttonStyle(.plain)
                .accessibilityLabel("Home")
        } else {
            icon
        }
    }
}

extension PanuraHeader where Content == AnyView {
    /// The plain form: a bold title where the address pill would be. Used by
    /// every screen that is not the browser or Home.
    init(_ title: String, onTapGlyph: (() -> Void)? = nil) {
        self.onTapGlyph = onTapGlyph
        self.content = AnyView(
            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .padding(.leading, 4)
        )
    }
}

/// The address pill, shared by Home and the browser so the two read as one bar.
///
/// Two lines when a page is loaded — title over URL, as Android does — because
/// a URL alone is unreadable at this width and a title alone hides where you
/// are. One line otherwise, carrying the hint.
struct AddressPill<Leading: View, Trailing: View>: View {
    var title: String
    var url: String
    var placeholder: String
    /// A private session repaints the pill; the tint is passed in so the browser
    /// owns that decision rather than this view guessing.
    var background: Color
    var onTap: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    private var hasPage: Bool { !url.isEmpty && url != "about:blank" }

    var body: some View {
        HStack(spacing: 2) {
            leading
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 0) {
                    if hasPage, !title.isEmpty {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(url)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(hasPage ? url : placeholder)
                            .font(.subheadline)
                            .foregroundStyle(hasPage ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background(background, in: Capsule())
    }
}
