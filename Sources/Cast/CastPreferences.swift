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
    private static let muxKey = "cast.muxing"

    // MARK: televisions that cannot play audio and video separately

    /// Whether this TV should have its audio folded into its video — or nil
    /// where nobody has said.
    ///
    /// **Three states, not two, and the third is the useful one.** The default
    /// is now *mux when the stream needs it*: a master that declares its audio
    /// separately is one no Chromecast of this vintage can play, so waiting to
    /// be asked just means the first attempt fails. But a television that
    /// turns out to manage the original perfectly well should not be made to
    /// pay for the bytes, and somebody who switches it off must have that
    /// respected on the next film. So: nil until answered, then exactly what
    /// was answered.
    ///
    /// Stored as a dictionary rather than two lists because the question has
    /// an answer per set and "absent" has to be distinguishable from "no".
    static func muxingChoice(on tv: String) -> Bool? {
        muxChoices()[normalised(tv)]
    }

    static func setMuxing(_ needed: Bool, on tv: String) {
        var current = muxChoices()
        current[normalised(tv)] = needed
        UserDefaults.standard.set(current, forKey: muxKey)
    }

    static func muxing() -> [String] {
        muxChoices().filter(\.value).keys.sorted()
    }

    private static func muxChoices() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: muxKey) as? [String: Bool]) ?? [:]
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
