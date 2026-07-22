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
    /// `hls` | `mp4` | `dash` hint from the manifest rule; drives the cast MIME
    /// type, which cannot be guessed from an extensionless URL.
    var contentType: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        url: URL,
        isLocal: Bool = false,
        durationSeconds: Double? = nil,
        thumbnailURL: URL? = nil,
        headers: [String: String] = [:],
        subtitles: [SubtitleTrack] = [],
        contentType: String? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isLocal = isLocal
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.headers = headers
        self.subtitles = subtitles
        self.contentType = contentType
    }
}

/// A found video reported by the browser extractor (parallels
/// `PanuraExtractor.onVideoFound(url, title)` on Android).
struct ExtractedVideo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let title: String
    let headers: [String: String]
    /// `hls` | `mp4` | `dash` from the manifest rule, when one matched.
    /// Extensionless manifests can't be identified from the URL alone.
    var contentType: String?
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
