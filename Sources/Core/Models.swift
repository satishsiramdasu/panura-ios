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

    init(
        id: String = UUID().uuidString,
        title: String,
        url: URL,
        isLocal: Bool = false,
        durationSeconds: Double? = nil,
        thumbnailURL: URL? = nil,
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isLocal = isLocal
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.headers = headers
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
