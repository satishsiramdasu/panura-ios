import Foundation

/// A playable media item — local file, remote stream, or an extracted video.
struct MediaItem: Identifiable, Hashable {
    let id: String
    var title: String
    var url: URL
    var isLocal: Bool
    var durationSeconds: Double?
    var thumbnailURL: URL?
    /// Headers for local playback. Narrowed by the site rule, because requiring
    /// `Origin` forces the stream through the local relay and libVLC sends the
    /// rest natively.
    var headers: [String: String] = [:]
    /// Everything captured at detection, untrimmed — what Android replays on
    /// every path.
    ///
    /// Casting must use this, not `headers`. A rule that lists only
    /// `user-agent` drops Cookie and Origin, which is fine for libVLC on this
    /// device and fatal for a TV fetching the same URL: a cookie-gated CDN
    /// refuses it, the TV stalls, and the stream looks broken on iOS while
    /// working from Android, which sends the full set.
    var castHeaders: [String: String] = [:]
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
        castHeaders: [String: String] = [:],
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
        // Falling back keeps every caller that has only one set working.
        self.castHeaders = castHeaders.isEmpty ? headers : castHeaders
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
    /// Rule-narrowed, for local playback.
    let headers: [String: String]
    /// Untrimmed, for casting — see `MediaItem.castHeaders`.
    var castHeaders: [String: String] = [:]
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
