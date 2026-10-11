import Foundation

/// What we have learned about a particular television.
///
/// Only one thing so far, and it is a thing no API can tell us: whether this TV
/// actually plays Dolby Vision correctly. A set that renders DV as noise reports
/// a perfectly successful playback, so there is nothing to catch and nothing to
/// query — the person watching it is the only reliable judge. When they say a
/// TV is fine with the original, that answer is kept, and clips stop being
/// converted for it.
///
/// Keyed by the name the TV advertises, which is what the person chose it by.
/// Two identically-named sets on one network would share an answer; that is a
/// fair trade for not asking the same question every time.
enum CastPreferences {
    private static let key = "cast.sendsOriginal"
    private static let muxKey = "cast.needsMuxing"

    // MARK: televisions that cannot play audio and video separately

    /// Whether this TV needs its audio folded into its video.
    ///
    /// Remembered per set, and remembered rather than detected, because there
    /// is nothing to detect: a Chromecast that cannot run two media pipelines
    /// does not say so — it loads the stream, shows a frame and stops, which is
    /// what a dozen unrelated faults also look like. Once somebody has turned
    /// muxing on for their old television and seen it work, that is the only
    /// reliable signal there will ever be, so it is kept.
    ///
    /// Off by default on purpose. Muxing routes the whole film through the
    /// phone, and most Cast hardware needs nothing of the sort.
    static func needsMuxing(on tv: String) -> Bool {
        muxNames().contains(normalised(tv))
    }

    static func setMuxing(_ needed: Bool, on tv: String) {
        var current = muxNames()
        if needed { current.insert(normalised(tv)) } else { current.remove(normalised(tv)) }
        UserDefaults.standard.set(Array(current), forKey: muxKey)
    }

    static func muxing() -> [String] {
        muxNames().sorted()
    }

    private static func muxNames() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: muxKey) ?? [])
    }

    static func allowsOriginal(on tv: String) -> Bool {
        names().contains(normalised(tv))
    }

    static func allowOriginal(on tv: String) {
        var current = names()
        current.insert(normalised(tv))
        UserDefaults.standard.set(Array(current), forKey: key)
    }

    /// For Settings, so a TV that was misjudged can be asked again.
    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: muxKey)
    }

    static func remembered() -> [String] {
        names().sorted()
    }

    private static func names() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func normalised(_ tv: String) -> String {
        tv.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
