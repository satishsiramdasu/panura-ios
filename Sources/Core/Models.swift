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
    /// What a *second device* should send: Referer and User-Agent, never Origin
    /// or Cookie.
    ///
    /// Casting must use this, not `headers`. A session cookie is bound to the IP
    /// and User-Agent that obtained it, so replaying it from a TV is worse than
    /// sending none — the origin sees a cookie it knows is wrong. Proven by
    /// casting one video from both phones to the same TV: Android's
    /// [User-Agent, Referer, …] played; iOS's [Origin, Cookie, Referer,
    /// User-Agent] got HTTP 200 with a body reading "security error".
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
    /// True when a manifest site rule claimed this URL. The probe must not read
    /// such a stream: those hosts hand out single-use tokens, and a probe that
    /// spends one leaves the player with a 410.
    var ruleMatched: Bool = false
    /// Liveness, from `StreamProbe`. `.skipped` for anything that isn't direct
    /// media — an embed page has nothing to probe.
    var probeState: StreamProbe.State = .skipped
    /// Resolution / size / HLS kind, once the probe has answered.
    var probeResult: StreamProbe.Result?

    /// Filename for the found-bar. The last path segment, except when that is a
    /// generic playlist name (`master.m3u8` and friends), where the descriptive
    /// parent segment says far more —
    /// `…/1080P_4000K_54254475.mp4/master.m3u8` → `1080P_4000K_54254475.mp4`.
    var fileLabel: String {
        let segments = url.path.split(separator: "/").filter { !$0.isEmpty }
        guard let last = segments.last else { return url.host ?? "Stream" }
        let generic: Set<String> = [
            "master.m3u8", "index.m3u8", "playlist.m3u8", "video.m3u8", "media.m3u8",
            "master.txt", "index.txt", "manifest.mpd", "stream.m3u8",
        ]
        if generic.contains(last.lowercased()), segments.count >= 2 {
            return String(segments[segments.count - 2])
        }
        return String(last)
    }
}

extension Array where Element == ExtractedVideo {
    /// List order: reachable streams first, best resolution first inside that,
    /// dead ones last. Stable, so equal-ranked rows keep detection order.
    ///
    /// `.skipped` is an embed page rather than a probed stream — no resolution
    /// to compare, but nothing says it is dead either, so it sits below
    /// confirmed streams and above the ones that failed.
    func byQuality() -> [ExtractedVideo] {
        func rank(_ v: ExtractedVideo) -> Int {
            switch v.probeState {
            case .active: return 0
            case .pending: return 1
            case .skipped: return 2
            case .inactive: return 3
            }
        }
        return enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let (pa, pb) = (a.element.probeResult?.pixels ?? 0, b.element.probeResult?.pixels ?? 0)
            if pa != pb { return pa > pb }
            return a.offset < b.offset
        }.map(\.element)
    }
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
