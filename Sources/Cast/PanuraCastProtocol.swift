import Foundation

/// Wire format for PanuraCast — the phone↔TV channel used by the Panura Android
/// TV receiver. Field names and defaults mirror `CastMessage` in the Android app
/// exactly; the TV decodes with kotlinx.serialization, which is strict about
/// names and tolerant of missing values, so every field here decodes with a
/// default and encodes unconditionally.
struct CastMessage: Codable {
    /// "stream" | "stop" | "ping" | "pong" | "control" | "status" | "hello"
    var type: String
    var streamUrl: String = ""
    var proxyUrl: String = ""
    var title: String = ""
    var headers: [String: String] = [:]
    /// "direct" — the TV fetches from the CDN itself — or "proxy", via the phone.
    var mode: String = ""
    var subtitles: [CastSubtitle] = []
    /// Deliberately separate from `headers`: the subtitle host and the video CDN
    /// often want opposite things, and a CDN that 429s on a Referer would take
    /// the captions down with it if the two sets were shared.
    var subtitleHeaders: [String: String] = [:]

    // hello, both directions
    var deviceName: String = ""
    var incognito: Bool = false

    // control, phone → TV
    /// "playpause" | "play" | "pause" | "seekBy" | "seekTo" | "volume"
    /// | "audioTrack" | "subtitleTrack" | "subtitleOff"
    var command: String = ""
    var valueLong: Int64 = 0
    var valueFloat: Float = 0

    // status, TV → phone
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var isPlaying: Bool = false
    var isLive: Bool = false
    var volume: Float = 1
    var audioTracks: [CastTrackInfo] = []
    var subtitleTracks: [CastTrackInfo] = []

    init(type: String) { self.type = type }

    /// Hand-written so an absent field takes its default instead of failing the
    /// whole message — the TV omits everything it isn't currently sending.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        streamUrl = try c.decodeIfPresent(String.self, forKey: .streamUrl) ?? ""
        proxyUrl = try c.decodeIfPresent(String.self, forKey: .proxyUrl) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        subtitles = try c.decodeIfPresent([CastSubtitle].self, forKey: .subtitles) ?? []
        subtitleHeaders = try c.decodeIfPresent([String: String].self, forKey: .subtitleHeaders) ?? [:]
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        incognito = try c.decodeIfPresent(Bool.self, forKey: .incognito) ?? false
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        valueLong = try c.decodeIfPresent(Int64.self, forKey: .valueLong) ?? 0
        valueFloat = try c.decodeIfPresent(Float.self, forKey: .valueFloat) ?? 0
        positionMs = try c.decodeIfPresent(Int64.self, forKey: .positionMs) ?? 0
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        audioTracks = try c.decodeIfPresent([CastTrackInfo].self, forKey: .audioTracks) ?? []
        subtitleTracks = try c.decodeIfPresent([CastTrackInfo].self, forKey: .subtitleTracks) ?? []
    }
}

/// A sidecar subtitle captured on the page. The TV has no browser, so it can
/// only show captions handed to it explicitly.
struct CastSubtitle: Codable {
    var url: String
    var label: String
    var lang: String = ""

    init(url: String, label: String, lang: String = "") {
        self.url = url
        self.label = label
        self.lang = lang
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        lang = try c.decodeIfPresent(String.self, forKey: .lang) ?? ""
    }
}

/// A track the TV reports it can switch to.
struct CastTrackInfo: Codable, Identifiable, Hashable {
    var id: Int
    var label: String
    var selected: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? -1
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
    }
}

/// Playback state as last reported by the TV.
struct PanuraPlayback: Equatable {
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var isPlaying = false
    var isLive = false
    var volume: Float = 1
    var audioTracks: [CastTrackInfo] = []
    var subtitleTracks: [CastTrackInfo] = []
}

extension CastTrackInfo: Equatable {
    static func == (a: CastTrackInfo, b: CastTrackInfo) -> Bool {
        a.id == b.id && a.label == b.label && a.selected == b.selected
    }
}
