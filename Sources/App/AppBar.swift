import SwiftUI

/// Where you can be.
///
/// All five are equals now. They were not: Home, Web and Videos had seats in a
/// bottom bar and Stream and Settings lived behind a grid button, which is two
/// navigation mechanisms for one list of destinations — and the split was made
/// by how often a place is visited rather than by what it is. The drawer holds
/// all five, in one list, with room to say what each one is for.
enum AppDestination: Hashable, CaseIterable {
    case home, web, videos, stream, settings

    var title: String {
        switch self {
        // "Browser", not "Web": the word says the same thing the listing does,
        // and the listing is "Panura: Video Browser, TV Cast". "Web" only reads
        // as *web videos, as against local ones* to someone who already knows
        // the app; "Browser" tells a new one there is a browser in here, which
        // is what they came for.
        case .home: return "Home"
        case .web: return "Browser"
        case .videos: return "Videos"
        case .stream: return "Network Stream"
        case .settings: return "Settings"
        }
    }

    /// What the row is for, for the drawer and Home's cards. The rarely-pressed
    /// destinations are exactly the ones a glyph and a noun leave people
    /// guessing at.
    var detail: String {
        switch self {
        case .home: return "Shortcuts, history and what you were watching"
        case .web: return "Find and cast videos on any site"
        case .videos: return "Everything in this phone's library"
        case .stream: return "Play a link straight from its address"
        case .settings: return "Playback, browser, subtitles, gestures"
        }
    }

    func icon(selected: Bool) -> String {
        switch self {
        case .home: return selected ? "house.fill" : "house"
        case .web: return selected ? "globe.americas.fill" : "globe"
        case .videos: return selected ? "film.fill" : "film"
        case .stream: return "link"
        case .settings: return selected ? "gearshape.fill" : "gearshape"
        }
    }

    /// The tile behind the glyph, so a list of five can be found by colour
    /// rather than read top to bottom every time.
    var tint: Color {
        switch self {
        case .home: return PanuraTheme.accent
        case .web: return PanuraTheme.accent
        case .videos: return .green
        case .stream: return .cyan
        case .settings: return .gray
        }
    }
}

/// What the shell reserves at the bottom of the screen.
///
/// There is no bottom bar any more, but the home indicator is still drawn over
/// whatever is down there, by the system, whatever the app puts under it. This
/// is the smallest strip that keeps it clear of a row of buttons: 34pt — the
/// full inset — left an obvious empty band, and 8pt put the indicator on top of
/// the controls.
enum AppChrome {
    static let bottomInset: CGFloat = 16
}
