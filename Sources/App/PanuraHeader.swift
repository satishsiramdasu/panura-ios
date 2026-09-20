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
/// The glyph is the app's own launcher artwork — the adaptive icon's foreground,
/// trimmed of its safe-zone padding — so the header wears the same mark as the
/// home screen, as Android's does. `AppIcon` cannot be drawn inside the app, so
/// the glyph ships as its own image set.
struct PanuraHeader<Content: View>: View {
    /// Tapping the glyph goes Home, as it does on Android's browser. nil leaves
    /// it decorative, which is what every screen that IS a destination wants.
    var onTapGlyph: (() -> Void)?
    /// The glyph is doing something right now — in the browser, holding the
    /// site panel open. Drawn as the pressed state a button would have.
    var glyphActive: Bool = false
    /// Something needs attention behind the glyph. The browser marks it when a
    /// protection is switched off for the site in the address bar.
    var glyphMarked: Bool = false
    var glyphLabel: String = "Home"
    /// Recolours the mark itself. Private browsing uses it.
    ///
    /// The bar used to turn purple instead — the address pill repainted behind
    /// the text — which read as a theme change rather than as a state, and made
    /// the one element you actually type into the hardest thing on screen to
    /// look at. Colouring the mark says the same thing in the place the eye
    /// already goes, and leaves the page's own chrome alone.
    var glyphTint: Color?
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
        let mark = Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 30, height: 30)
        let icon = Group {
            if let glyphTint {
                // `sourceAtop` over a compositing group paints every opaque
                // pixel of the mark and nothing around it — a flat silhouette
                // in the tint, rather than the muddy result of multiplying a
                // colour through artwork that already has its own.
                mark
                    .overlay(glyphTint.blendMode(.sourceAtop))
                    .compositingGroup()
            } else {
                mark
            }
        }
            .frame(width: 44, height: 44)
            .background(
                Circle()
                    .fill(glyphActive ? PanuraTheme.accentSoft : .clear)
                    .frame(width: 40, height: 40)
            )
            // A brand mark cannot be struck through the way a shield can, so
            // the state goes beside it: one dot, ringed in the bar's own colour
            // so it reads as sitting on top rather than as part of the logo.
            .overlay(alignment: .topTrailing) {
                if glyphMarked {
                    Circle()
                        .fill(PanuraTheme.onSurfaceVariant)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(PanuraTheme.surfaceContainer, lineWidth: 2))
                        .offset(x: -7, y: 9)
                }
            }
        if let onTapGlyph {
            Button(action: onTapGlyph) { icon }
                .buttonStyle(.plain)
                .accessibilityLabel(glyphLabel)
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
