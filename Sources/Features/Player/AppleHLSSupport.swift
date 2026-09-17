import Foundation

/// Spots the HLS streams Apple's players cannot play before they waste the
/// user's time.
///
/// The case that matters is HEVC carried in MPEG-TS segments. Apple's players
/// decode HEVC in HLS only from fMP4 segments; given TS they do not fail — they
/// sit on the loading spinner indefinitely, so there is no error to react to.
/// VLC plays the same stream without complaint. Such streams are common on the
/// sites this app is for, usually with the playlist named .txt and each
/// segment given a decoy extension (.ttf, .svg, .gif), which is why this reads
/// the bytes rather than trusting any name.
///
/// Reads at most the master playlist, one media playlist and the first 64 KB of
/// one segment, and gives up after ten seconds. Any doubt answers "supported":
/// the no-picture watch in `AVPlayerModel` is the backstop.
enum AppleHLSSupport {
    static func isUnsupported(_ item: MediaItem) async -> Bool {
        guard !item.isLocal,
              item.contentType?.lowercased() == "hls" || item.url.path.lowercased().hasSuffix(".m3u8")
        else { return false }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await inspect(item) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }

    private static func inspect(_ item: MediaItem) async -> Bool {
        guard let master = await text(item.url, headers: item.headers) else { return false }

        var media = master
        var base = item.url
        var hevcDeclared = false
        if master.contains("#EXT-X-STREAM-INF") {
            guard let variant = firstVariant(master, base: item.url),
                  let variantText = await text(variant.url, headers: item.headers)
            else { return false }
            hevcDeclared = variant.codecs.contains { ["hvc1", "hev1", "dvh1", "dvhe"].contains(String($0.prefix(4))) }
            media = variantText
            base = variant.url
        }

        // An init segment means fMP4, which Apple decodes whatever the codec.
        guard !media.contains("#EXT-X-MAP"),
              let segment = firstSegment(media, base: base)
        else { return false }

        // Encrypted segments cannot be read here; the declared codec decides.
        if media.contains("METHOD=AES-128") || media.contains("METHOD=SAMPLE-AES") { return hevcDeclared }

        guard let head = await ProbeHTTP.get(segment, headers: item.headers, range: 0..<65_536, limit: 65_536) else {
            return false
        }
        let bytes = [UInt8](StreamProxy.stripDecoyHeader(head.data))
        guard bytes.count >= 188 * 2, bytes[0] == 0x47, bytes[188] == 0x47 else { return false }   // not TS
        return hevcDeclared || transportStreamCarriesHEVC(bytes)
    }

    // MARK: playlists

    private static func text(_ url: URL, headers: [String: String]) async -> String? {
        guard let response = await ProbeHTTP.get(url, headers: headers, limit: 1_000_000),
              let text = String(data: response.data, encoding: .utf8),
              text.contains("#EXTM3U")
        else { return nil }
        return text
    }

    private static func firstVariant(_ text: String, base: URL) -> (url: URL, codecs: [String])? {
        var codecs: [String]?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                codecs = codecList(line)
            } else if let found = codecs, !line.isEmpty, !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { return nil }
                return (url, found)
            }
        }
        return nil
    }

    private static func codecList(_ line: String) -> [String] {
        guard let start = line.range(of: "CODECS=\"") else { return [] }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return [] }
        return rest[..<end].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func firstSegment(_ text: String, base: URL) -> URL? {
        var afterInf = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                afterInf = true
            } else if afterInf, !line.isEmpty, !line.hasPrefix("#") {
                return URL(string: line, relativeTo: base)?.absoluteURL
            }
        }
        return nil
    }

    // MARK: transport stream

    /// Whether the segment's program map lists an HEVC stream (type 0x24).
    private static func transportStreamCarriesHEVC(_ b: [UInt8]) -> Bool {
        var pmtPID: Int?
        var i = 0
        while i + 188 <= b.count {
            defer { i += 188 }
            guard b[i] == 0x47, b[i + 1] & 0x40 != 0 else { continue }   // packet start with a new table
            let pid = (Int(b[i + 1] & 0x1F) << 8) | Int(b[i + 2])
            var payload = i + 4
            if (b[i + 3] >> 4) & 2 != 0 { payload += 1 + Int(b[i + 4]) }
            guard payload < i + 188 else { continue }
            let table = payload + 1 + Int(b[payload])   // skip the pointer field
            guard table + 12 < i + 188 else { continue }

            if pid == 0, pmtPID == nil {
                pmtPID = (Int(b[table + 10] & 0x1F) << 8) | Int(b[table + 11])
            } else if let pmt = pmtPID, pid == pmt {
                let length = (Int(b[table + 1] & 0x0F) << 8) | Int(b[table + 2])
                let end = min(table + 3 + length - 4, i + 188)
                var j = table + 12 + ((Int(b[table + 10] & 0x0F) << 8) | Int(b[table + 11]))
                while j + 5 <= end {
                    if b[j] == 0x24 { return true }
                    j += 5 + ((Int(b[j + 3] & 0x0F) << 8) | Int(b[j + 4]))
                }
                return false
            }
        }
        return false
    }
}

/// Bounded GETs for probing: never more than `limit` bytes are read, whatever
/// the server decides to send.
enum ProbeHTTP {
    struct Response {
        var data: Data
        var status: Int
    }

    static func get(_ url: URL, headers: [String: String], range: Range<Int64>? = nil, limit: Int) async -> Response? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        }

        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
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
        return Response(data: data, status: status)
    }
}
