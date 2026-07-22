import Foundation

/// A playable media item — local file, remote stream, or an extracted video.
struct MediaItem: Identifiable, Hashable {
    let id: String
    var title: String
    var url: URL
    var isLocal: Bool
    var durationSeconds: Double?
    var thumbnailURL: URL?
    /// Headers captured during extraction (Referer, cookies, etc.) needed to
    /// replay gated streams — mirrors the Android "full header set" rule.
    var headers: [String: String] = [:]
    /// Sidecar subtitles sniffed from the page, sideloaded into the player.
    var subtitles: [SubtitleTrack] = []

    init(
        id: String = UUID().uuidString,
        title: String,
        url: URL,
        isLocal: Bool = false,
        durationSeconds: Double? = nil,
        thumbnailURL: URL? = nil,
        headers: [String: String] = [:],
        subtitles: [SubtitleTrack] = []
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isLocal = isLocal
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.headers = headers
        self.subtitles = subtitles
    }
}

/// A found video reported by the browser extractor (parallels
/// `PanuraExtractor.onVideoFound(url, title)` on Android).
struct ExtractedVideo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let title: String
    let headers: [String: String]
}

/// A sidecar subtitle track sniffed from the page (`onSubtitleFound`).
struct SubtitleTrack: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let label: String
    let language: String

    /// Best available display name.
    var displayName: String {
        if !label.isEmpty { return label }
        if !language.isEmpty { return language.uppercased() }
        return url.lastPathComponent
    }
}
