import Foundation
import FirebaseCore
import FirebaseAnalytics

/// The playback events that decide whether VLC stays in the app: how often Auto
/// hands a video to VLC, why, on what kind of source, and whether VLC then
/// plays it.
///
/// Types only, by design. No URL, host, title or file name is ever sent — the
/// privacy policy says what leaves the device, and a page address is not on it.
enum PlayerAnalytics {
    /// `switched` is why Auto handed this video to VLC — extension, failed,
    /// unsupported — or "no".
    static func opened(engine: String, item: MediaItem, switchReason: String?) {
        log("player_open", engine: engine, item: item, extra: ["switched": switchReason ?? "no"])
    }

    /// An error the user actually saw: a forced engine, or VLC after a switch.
    static func failed(engine: String, item: MediaItem) {
        log("player_failed", engine: engine, item: item)
    }

    /// Whether VLC played what the Apple player could not.
    static func switchResult(played: Bool, item: MediaItem, reason: String) {
        log("vlc_switch_result", engine: "vlc", item: item, extra: [
            "result": played ? "played" : "failed",
            "reason": reason,
        ])
    }

    /// The container or protocol, from the site rule's type or the extension.
    static func kind(_ item: MediaItem) -> String {
        let type = item.contentType?.lowercased() ?? ""
        let path = item.url.path.lowercased()
        if type == "hls" || path.hasSuffix(".m3u8") { return "hls" }
        if type == "dash" || path.hasSuffix(".mpd") { return "dash" }
        for ext in ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "ts", "wmv"] where path.hasSuffix("." + ext) {
            return ext
        }
        return type == "mp4" ? "mp4" : "other"
    }

    private static func log(_ name: String, engine: String, item: MediaItem, extra: [String: String] = [:]) {
        // Builds without GoogleService-Info.plist never configure Firebase.
        guard FirebaseApp.app() != nil else { return }
        var parameters: [String: Any] = [
            "engine": engine,
            "kind": kind(item),
            "source": item.isLocal ? "local" : "web",
        ]
        for (key, value) in extra { parameters[key] = value }
        Analytics.logEvent(name, parameters: parameters)
    }
}
