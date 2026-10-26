import AVFoundation
import Foundation

/// The precheck behind the "Video link" dialog: what a tapped link to a video
/// file actually is, before anyone is offered Play, Cast and Save.
///
/// A tap on `…/movie.mp4` used to be cancelled and added to the found list
/// unread. That is right for a link that is what it says, and wrong for one
/// that is not: a page ending in `.mp4` that answers with HTML, a file that has
/// been taken down, a download that says nothing about its size. This asks
/// first — one small ranged request, then, for a file the Apple player can
/// open, its length and picture size from the container itself.
///
/// **Fail-safe, as `StreamProbe` is.** A 403 or 405 to this request is not
/// proof the video is unplayable — the player replays the full captured header
/// set — so it still gets a dialog, just with less in it. Only 404/410 count as
/// gone, and only a body that is plainly a web page counts as not a video.
enum DirectLinkProbe {
    struct Details: Hashable {
        /// "MP4 video", "HLS stream" — what it is, in words.
        var kind: String
        var size: String?
        var duration: String?
        var resolution: String?
        /// Whether the server takes byte ranges, which is what seeking and
        /// resuming a download both need.
        var seekable: Bool?
    }

    enum Verdict {
        case video(Details)
        /// 404/410: the link is dead.
        case gone
        /// An HTML page, say, wearing a video's file name.
        case notVideo
    }

    static func check(url: URL, headers: [String: String]) async -> Verdict {
        if isPlaylist(url) { return await checkPlaylist(url, headers: headers) }

        var reply = await ranged(url, headers: headers)
        // A referer whitelist rejects the one it was handed and allows none at
        // all, so a refusal gets one bare retry — the same thing `StreamProbe`
        // does for the same reason.
        if let first = reply, !(200..<300).contains(first.status), !gone(first.status),
           let bare = await ranged(url, headers: [:]), (200..<300).contains(bare.status) {
            reply = bare
        }
        guard let reply else { return .video(Details(kind: kind(for: url, mime: nil))) }
        if gone(reply.status) { return .gone }

        var details = Details(kind: kind(for: url, mime: reply.mime))
        if (200..<300).contains(reply.status) {
            if looksLikePage(reply.mime) { return .notVideo }
            if let total = reply.total, total > 0 { details.size = StreamProbe.formatSize(total) }
            details.seekable = reply.status == 206 || reply.acceptsRanges
            if canReadContainer(url, mime: reply.mime) {
                let facts = await containerFacts(url, headers: headers)
                details.duration = facts.duration
                details.resolution = facts.resolution
            }
        }
        return .video(details)
    }

    // MARK: playlists

    private static func isPlaylist(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".m3u8") || path.hasSuffix(".mpd") || path.contains("/hls/")
    }

    /// `StreamProbe` already reads a playlist for running time, size range and
    /// resolution; asking it again would be a second implementation.
    private static func checkPlaylist(_ url: URL, headers: [String: String]) async -> Verdict {
        let outcome = await StreamProbe.probe(url: url, headers: headers, ruleMatched: false)
        guard outcome.active else { return .gone }
        let r = outcome.result
        let kind: String
        switch r?.hlsType {
        case "Adaptive": kind = "HLS stream · several qualities"
        case "Single": kind = "HLS stream"
        default: kind = url.path.lowercased().hasSuffix(".mpd") ? "DASH stream" : "HLS stream"
        }
        return .video(Details(
            kind: kind, size: r?.fileSize, duration: r?.duration, resolution: r?.resolution
        ))
    }

    // MARK: the ranged request

    private struct Reply {
        var status: Int
        var mime: String?
        var total: Int64?
        var acceptsRanges: Bool
    }

    private static func gone(_ status: Int) -> Bool { StreamProbe.goneStatuses.contains(status) }

    /// The first two kilobytes, not a HEAD: plenty of servers refuse HEAD and
    /// none refuse a small GET, and a 206 names the whole length in
    /// `Content-Range` besides.
    private static func ranged(_ url: URL, headers: [String: String]) async -> Reply? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        for (name, value) in headers where !value.isEmpty {
            let key = name.lowercased()
            guard key != "host", key != "content-length", key != "range" else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if headers.keys.first(where: { $0.lowercased() == "user-agent" }) == nil {
            request.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
        }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        var total: Int64?
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let last = range.split(separator: "/").last, let n = Int64(last) {
            total = n
        } else if http.statusCode == 200, http.expectedContentLength > 0 {
            total = http.expectedContentLength
        }
        return Reply(
            status: http.statusCode,
            mime: http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
            total: total,
            acceptsRanges: http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        )
    }

    private static func looksLikePage(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.hasPrefix("text/html") || mime.hasPrefix("application/json")
            || mime.hasPrefix("application/xhtml")
    }

    // MARK: naming it

    private static func kind(for url: URL, mime: String?) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "MP4 video"
        case "mkv": return "MKV video"
        case "webm": return "WebM video"
        case "mov": return "QuickTime video"
        case "avi": return "AVI video"
        case "ts": return "MPEG-TS video"
        case "flv": return "FLV video"
        default: break
        }
        if let mime, mime.hasPrefix("video/") {
            return mime.dropFirst(6).uppercased() + " video"
        }
        return "Video file"
    }

    // MARK: the container itself

    /// The Apple player's own containers. An MKV or WebM is not asked: AVFoundation
    /// cannot open it, and a request that cannot succeed only costs the dialog
    /// its timeout.
    private static func canReadContainer(_ url: URL, mime: String?) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
            || (mime?.hasPrefix("video/mp4") ?? false)
    }

    /// Length and picture size, from the file's own header. Bounded: an MP4
    /// with its index at the far end has to be reached for, and six seconds is
    /// as long as a dialog should wait for a line of small print.
    private static func containerFacts(
        _ url: URL, headers: [String: String]
    ) async -> (duration: String?, resolution: String?) {
        await withTaskGroup(of: (String?, String?).self) { group in
            group.addTask {
                let options: [String: Any] = headers.isEmpty
                    ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
                let asset = AVURLAsset(url: url, options: options)
                var length: String?
                var picture: String?
                if let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 {
                    length = clock(time.seconds)
                }
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
                    picture = "\(Int(size.width))×\(Int(size.height))"
                }
                return (length, picture)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                return (nil, nil)
            }
            let first = await group.next() ?? (nil, nil)
            group.cancelAll()
            return first
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return s > 0 && m < 10 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }
}
