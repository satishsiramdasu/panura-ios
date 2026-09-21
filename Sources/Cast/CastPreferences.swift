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
