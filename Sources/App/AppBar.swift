import SwiftUI

/// Where you can be.
///
/// All five are equals now. They were not: Home, Web and Videos had seats in a
/// bottom bar and Stream and Settings lived behind a grid button, which is two
/// navigation mechanisms for one list of destinations — and the split was made
/// by how often a place is visited rather than by what it is. The drawer holds
/// all five, in one list, with room to say what each one is for.
enum AppDestination: Hashable, CaseIterable {
    case home, web, videos, stream, watchLater, settings
    /// Behind the shell's `+`. Neither is built yet — see `ComingSoonView`, and
    /// `FeatureFlags.showsPlannedTabs`, which must be off for a submission.
    case iptv, ftp

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
        case .watchLater: return "Watch Later"
        case .settings: return "Settings"
        case .iptv: return "IPTV"
        case .ftp: return "FTP"
        }
    }

    /// What the row is for, for the drawer and Home's cards. The rarely-pressed
    /// destinations are exactly the ones a glyph and a noun leave people
    /// guessing at.
    var detail: String {
        switch self {
        case .home: return "Bookmarks, history and what you were watching"
        case .web: return "Find and cast videos on any site"
        case .videos: return "Everything in this phone's library"
        case .stream: return "Play a link straight from its address"
        case .watchLater: return "Pages and videos you set aside"
        case .settings: return "Playback, browser, subtitles, gestures"
        case .iptv: return "Play a playlist you supply yourself"
        case .ftp: return "Open a server on your own network"
        }
    }

    /// What this destination is called in storage.
    ///
    /// Spelled out rather than taken from a `RawValue`, because these strings
    /// outlive the source: they are written into `UserDefaults` by `TabSet`,
    /// and renaming a case must not quietly empty somebody's tab strip.
    var key: String {
        switch self {
        case .home: return "home"
        case .web: return "web"
        case .videos: return "videos"
        case .stream: return "stream"
        case .watchLater: return "watchLater"
        case .settings: return "settings"
        case .iptv: return "iptv"
        case .ftp: return "ftp"
        }
    }

    init?(key: String) {
        guard let match = AppDestination.allCases.first(where: { $0.key == key }) else {
            return nil
        }
        self = match
    }

    func icon(selected: Bool) -> String {
        switch self {
        case .home: return selected ? "house.fill" : "house"
        case .web: return selected ? "globe.americas.fill" : "globe"
        case .videos: return selected ? "film.fill" : "film"
        case .stream: return "link"
        case .watchLater: return selected ? "clock.fill" : "clock"
        case .settings: return selected ? "gearshape.fill" : "gearshape"
        case .iptv: return selected ? "tv.fill" : "tv"
        case .ftp: return selected ? "folder.fill" : "folder"
        }
    }

    /// The colour this destination owns.
    ///
    /// Three things wear it: the tab while it is selected, the screen's ground,
    /// and whatever bar that screen draws across its top - the browser's address
    /// row, the Videos toolbar. One colour for the three is what makes the tab
    /// read as the front of the panel rather than a lit button, and the panel's
    /// own controls read as part of the panel rather than as furniture resting
    /// on it.
    ///
    /// **The hue is the one `tint` already gives the destination's card on
    /// Home**, taken a long way down in value: amber for the browser, green for
    /// Videos, blue for IPTV, teal for FTP, purple for Watch Later. Home's card
    /// is the app's own amber, and Home takes no tint at all - which is the one
    /// deliberate break, because Home is where the brand lives and a tinted
    /// Home would make the accent look like one more tab colour rather than
    /// the app's. The first pass invented a second palette for the tabs, so
    /// the card you pressed and the panel it opened disagreed about what colour
    /// that place is.
    ///
    /// All of them stay dark and barely saturated. The hue only has to be
    /// enough to tell one tab from the next at a glance; any more and the app
    /// stops being a dark app with an amber accent and starts being four
    /// differently coloured apps behind one header.
    ///
    /// - Parameter privateBrowsing: repaints the Browser tab violet. Private
    ///   mode is the more important fact about the browser while it is on, and
    ///   the rest of that screen - pill, mark, menu row - already says so.
    func chrome(privateBrowsing: Bool = false) -> Color {
        if privateBrowsing, self == .web { return PanuraTheme.incognitoSurface }
        switch self {
        case .home: return PanuraTheme.surfaceContainerHigh
        case .web: return Color(hex: 0x2A2113)
        case .videos: return Color(hex: 0x15291C)
        case .stream: return Color(hex: 0x12272C)
        case .watchLater: return Color(hex: 0x201932)
        case .settings: return PanuraTheme.surfaceContainerHigh
        case .iptv: return Color(hex: 0x16223A)
        case .ftp: return Color(hex: 0x112826)
        }
    }

    /// The darker half of the pair: the header and the ground the tabs are cut
    /// out of.
    ///
    /// Same hue, further down. The strip only reads as a strip if what is
    /// behind it is darker than the tab in front of it, and carrying the hue
    /// down rather than falling back to neutral black is what makes the whole
    /// top of the screen belong to the tab you are in.
    func chromeDeep(privateBrowsing: Bool = false) -> Color {
        if privateBrowsing, self == .web { return Color(hex: 0x14101E) }
        switch self {
        case .home: return AppChrome.bar
        case .web: return Color(hex: 0x15110A)
        case .videos: return Color(hex: 0x0A1710)
        case .stream: return Color(hex: 0x08161A)
        case .watchLater: return Color(hex: 0x110D1D)
        case .settings: return AppChrome.bar
        case .iptv: return Color(hex: 0x0A1121)
        case .ftp: return Color(hex: 0x081715)
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
        case .watchLater: return .purple
        case .settings: return .gray
        // Blue, not pink. It is the tab's colour too now, and a pink header
        // over an amber-accented dark app was the one combination in the set
        // that read as a mistake.
        case .iptv: return .blue
        case .ftp: return .teal
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

    /// The ground the header and the tab strip sit on.
    ///
    /// Darker than every screen, which is the whole job: the tabs are cut out
    /// of this, and a selected one is filled with its screen's colour, so the
    /// strip only reads as a strip if what is behind it is darker than anything
    /// in front of it.
    static let bar = Color(hex: 0x0A0A0A)

    /// Four seats across, whatever the screen width, with a fifth left peeking
    /// over the edge rather than squeezed in.
    ///
    /// Four is what fits a 375pt phone with a readable label under each glyph.
    /// Sizing to the count instead would shrink every tab as the row grew, so
    /// the day a fifth arrives the other four would get worse - and nothing
    /// would say there was more to see. A fixed width and a scroll view says
    /// it by showing the edge of the next one.
    static let tabsPerRow: CGFloat = 4

    /// A 375-point phone: iPhone SE 2 and 3, the 12 and 13 mini, and the 8.
    ///
    /// The floor, not a guess - the deployment target is 16.4 and the 320pt SE
    /// of 2016 stops at iOS 15. The next size up is 390, so the threshold has
    /// 10 points of daylight on each side and cannot drift onto the wrong
    /// device.
    ///
    /// Read once. `UIScreen` is fixed for the life of the process on a phone,
    /// and re-reading it per layout pass would cost more than the seven points
    /// it saves.
    static let isNarrow: Bool = UIScreen.main.bounds.width < 380

    /// What the header spends on air rather than on the address.
    ///
    /// On a 375pt phone the title and URL get 109 points between the glyph and
    /// the chevrons - about eighteen characters - so every point of padding is
    /// a character the user cannot read. On 390 and up there is room, and
    /// tightening it there would only make the bar look cramped for nothing.
    static var headerPadding: CGFloat { isNarrow ? 4 : 6 }
    static var headerSpacing: CGFloat { isNarrow ? 3 : 4 }
    /// Back and forward. 14pt glyphs either way, so the target stays well
    /// clear of a fingertip at both widths.
    static var pillNavWidth: CGFloat { isNarrow ? 28 : 30 }
}
