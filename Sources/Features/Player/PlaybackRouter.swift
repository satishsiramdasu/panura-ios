import Foundation

/// How the Apple player opens an item.
enum PlaybackRoute: String {
    /// As is — what almost everything needs.
    case direct
    /// An HLS stream whose playlist or init segment names `hev1`: through the
    /// relay, which renames it to `hvc1`.
    case hevcTagStream = "hevc_tag_stream"
    /// An MP4 whose sample entries are `hev1`: through `HEVCTagLoader`.
    case hevcTagFile = "hevc_tag_file"
}

struct PlaybackPlan {
    var route: PlaybackRoute = .direct
    var file: HEVCTagLoader.Source?

    static let direct = PlaybackPlan()
}

/// Looks at an item before AVPlayer's verdict is in, to find the one packaging
/// problem that can be repaired on the way through: an HEVC `hev1` tag.
///
/// Runs beside a direct start, never before it, so a normal stream pays
/// nothing in startup time. Only playlists and MP4s are inspected, only the
/// bytes that answer the question are read — the playlists, one init segment,
/// a file's top-level box headers and its `moov` — and any doubt resolves to
/// `.direct`. The probe gives up after eight seconds.
enum PlaybackRouter {
    static func worthProbing(_ item: MediaItem) -> Bool {
        isStream(item) || isFile(item)
    }

    static func plan(for item: MediaItem) async -> PlaybackPlan {
        await withTaskGroup(of: PlaybackPlan?.self) { group in
            group.addTask { await inspect(item) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .direct
        }
    }

    private static func inspect(_ item: MediaItem) async -> PlaybackPlan {
        if isStream(item) { return await inspectStream(item) }
        if isFile(item) { return await inspectFile(item) }
        return .direct
    }

    private static func isStream(_ item: MediaItem) -> Bool {
        !item.isLocal && (item.contentType?.lowercased() == "hls" || item.url.path.lowercased().hasSuffix(".m3u8"))
    }

    private static func isFile(_ item: MediaItem) -> Bool {
        let path = item.url.path.lowercased()
        return item.contentType?.lowercased() == "mp4" || [".mp4", ".m4v", ".mov"].contains { path.hasSuffix($0) }
    }

    // MARK: HLS

    private static func inspectStream(_ item: MediaItem) async -> PlaybackPlan {
        guard let first = await ProbeHTTP.get(item.url, headers: item.headers, limit: 2_000_000),
              let text = String(data: first.data, encoding: .utf8), text.contains("#EXTM3U")
        else { return .direct }
        if HEVCTagPatcher.namesHEV1(text) { return PlaybackPlan(route: .hevcTagStream) }

        // A master names no init segment; its first variant does.
        var media = text
        var base = item.url
        if text.contains("#EXT-X-STREAM-INF"), let variant = firstVariant(text, base: item.url) {
            guard let fetched = await ProbeHTTP.get(variant, headers: item.headers, limit: 2_000_000),
                  let variantText = String(data: fetched.data, encoding: .utf8)
            else { return .direct }
            media = variantText
            base = variant
        }
        guard let initURL = initSegment(media, base: base),
              let segment = await ProbeHTTP.get(initURL, headers: item.headers, limit: 4_000_000),
              HEVCTagPatcher.patch(segment.data) != nil
        else { return .direct }
        return PlaybackPlan(route: .hevcTagStream)
    }

    private static func firstVariant(_ text: String, base: URL) -> URL? {
        var afterStreamInf = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                afterStreamInf = true
            } else if afterStreamInf, !line.isEmpty, !line.hasPrefix("#") {
                return URL(string: line, relativeTo: base)?.absoluteURL
            }
        }
        return nil
    }

    private static func initSegment(_ text: String, base: URL) -> URL? {
        for raw in text.components(separatedBy: .newlines) where raw.hasPrefix("#EXT-X-MAP") {
            guard let start = raw.range(of: "URI=\"") else { return nil }
            let rest = raw[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return URL(string: String(rest[..<end]), relativeTo: base)?.absoluteURL
        }
        return nil
    }

    // MARK: MP4

    private static func inspectFile(_ item: MediaItem) async -> PlaybackPlan {
        let source: HEVCTagLoader.Source?
        if item.isLocal {
            source = await localFile(item)
        } else {
            source = await remoteFile(item)
        }
        guard let source, !source.patches.isEmpty else { return .direct }
        return PlaybackPlan(route: .hevcTagFile, file: source)
    }

    private static func localFile(_ item: MediaItem) async -> HEVCTagLoader.Source? {
        guard let handle = try? FileHandle(forReadingFrom: item.url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let length = Int64(end)
        let read: (Int64, Int) async throws -> Data = { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
        guard let head = try? await read(0, 12),
              let patches = try? await HEVCTagPatcher.locate(length: length, read: read)
        else { return nil }
        return HEVCTagLoader.Source(
            url: item.url, headers: [:], isLocal: true, length: length,
            contentType: contentType(head), patches: patches
        )
    }

    private static func remoteFile(_ item: MediaItem) async -> HEVCTagLoader.Source? {
        let window: Int64 = 65_536
        guard let head = await ProbeHTTP.get(item.url, headers: item.headers, range: 0..<window, limit: Int(window)),
              head.status == 206,
              let length = head.totalLength
        else { return nil }   // no ranges, no resource loader: leave it to AVPlayer
        let url = item.url, headers = item.headers, cached = head.data
        let read: (Int64, Int) async throws -> Data = { offset, count in
            if offset + Int64(count) <= Int64(cached.count) {
                return cached.subdata(in: Int(offset)..<Int(offset) + count)
            }
            guard let part = await ProbeHTTP.get(url, headers: headers, range: offset..<(offset + Int64(count)), limit: count),
                  part.status == 206
            else { throw URLError(.badServerResponse) }
            return part.data
        }
        guard let patches = try? await HEVCTagPatcher.locate(length: length, read: read) else { return nil }
        return HEVCTagLoader.Source(
            url: url, headers: headers, isLocal: false, length: length,
            contentType: contentType(cached), patches: patches
        )
    }

    /// QuickTime when the ftyp brand says so, MPEG-4 otherwise.
    private static func contentType(_ head: Data) -> String {
        let brand = head.count >= 12 ? String(decoding: head.subdata(in: 8..<12), as: UTF8.self) : ""
        return brand == "qt  " ? "com.apple.quicktime-movie" : "public.mpeg-4"
    }
}

/// Bounded GETs for the probe: never more than `limit` bytes read, whatever
/// the server decides to send.
enum ProbeHTTP {
    struct Response {
        var data: Data
        var status: Int
        var contentRange: String?

        /// The total from "bytes 0-65535/1234567".
        var totalLength: Int64? {
            contentRange?.split(separator: "/").last.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        }
    }

    static func get(_ url: URL, headers: [String: String], range: Range<Int64>? = nil, limit: Int) async -> Response? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }

        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        guard (200..<300).contains(status) else { return nil }

        var data = Data()
        data.reserveCapacity(min(limit, 1 << 20))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            return nil
        }
        return Response(data: data, status: status, contentRange: http?.value(forHTTPHeaderField: "Content-Range"))
    }
}
