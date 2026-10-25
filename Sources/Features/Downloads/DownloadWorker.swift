import Foundation

/// Fetches one download to disk. Ported from Android's `OfflineSaveWorker`.
///
/// Throws `CancellationError` when paused — not a failure; everything already
/// on disk stays, and the next run skips it.
struct DownloadWorker: Sendable {
    let entry: DownloadEntry
    let onProgress: @Sendable (Int64, Int64) -> Void

    struct Outcome {
        let relativePath: String; let size: Int64; let duration: Double
        var subtitlePath: String? = nil
    }

    enum Failure: Error, LocalizedError {
        case http(Int)
        case invalidPlaylist
        case noSegments

        var errorDescription: String? {
            switch self {
            case let .http(code): return "The server answered \(code)."
            case .invalidPlaylist: return "The server did not return a valid playlist."
            case .noSegments: return "The playlist lists nothing to save."
            }
        }
    }

    /// The site refused the link rather than the network dropping.
    static func isLinkDead(_ error: Error) -> Bool {
        switch error as? Failure {
        case let .http(code)?: return [401, 403, 404, 410].contains(code)
        case .invalidPlaylist?: return true
        default: return false
        }
    }

    private static let parallelism = 4
    private static let retries = 3

    private var folder: URL { entry.folder }
    private var session: URLSession { .shared }

    func run() async throws -> Outcome {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let url = URL(string: entry.streamURL) else { throw Failure.invalidPlaylist }
        return entry.isHLS ? try await saveHLS(url) : try await saveFile(url)
    }

    // MARK: HLS, kept as HLS

    private struct Job: Sendable { let url: URL; let name: String; let range: String? }

    /// A media playlist rewritten to point at local names, and the downloads it
    /// needs. `prefix` keeps video ("v") and audio ("a") parts apart on disk.
    private struct Rewritten {
        var lines: [String] = []
        var jobs: [Job] = []
        var segments = 0
        var seconds = 0.0
    }

    private func rewrite(_ mediaText: String, base mediaURL: URL, prefix: String) -> Rewritten {
        var out = Rewritten()
        var key = 0
        var pendingRange: String?
        var nextOffset: Int64 = 0

        for raw in mediaText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-MAP") {
                guard let uri = Self.attribute("URI", in: line), let abs = URL(string: uri, relativeTo: mediaURL)?.absoluteURL else {
                    out.lines.append(line); continue
                }
                let isMap = line.hasPrefix("#EXT-X-MAP")
                let name = isMap ? "\(prefix)init.\(Self.ext(abs))" : "\(prefix)key\(key).bin"
                if !isMap { key += 1 }
                let range = isMap ? Self.byteRange(Self.attribute("BYTERANGE", in: line), from: 0)?.header : nil
                out.jobs.append(Job(url: abs, name: name, range: range))
                out.lines.append(isMap ? "#EXT-X-MAP:URI=\"\(name)\"" : line.replacingOccurrences(of: uri, with: name))
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                pendingRange = String(line.split(separator: ":", maxSplits: 1).last ?? "")
            } else if line.hasPrefix("#EXTINF") {
                let value = line.dropFirst(8).split(separator: ",").first.map(String.init) ?? ""
                out.seconds += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
                out.lines.append(line)
            } else if line.hasPrefix("#") {
                out.lines.append(line)
            } else if let abs = URL(string: line, relativeTo: mediaURL)?.absoluteURL {
                let name = String(format: "%@%05d.%@", prefix, out.segments, Self.ext(abs))
                out.segments += 1
                let range = Self.byteRange(pendingRange, from: nextOffset)
                if let range { nextOffset = range.next }
                pendingRange = nil
                out.jobs.append(Job(url: abs, name: name, range: range?.header))
                out.lines.append(name)
            }
        }
        // What was saved is a fixed set; without ENDLIST it reads as live.
        if !mediaText.contains("#EXT-X-ENDLIST") { out.lines.append("#EXT-X-ENDLIST") }
        return out
    }

    private func saveHLS(_ input: URL) async throws -> Outcome {
        let inputText = try await text(input)
        guard inputText.contains("#EXTM3U") || inputText.contains("#EXTINF") else {
            throw Failure.invalidPlaylist
        }
        // A master: the best rung, by its declared bandwidth. (The save sheet
        // normally hands over the rung it picked, which is a media playlist.)
        var mediaURL = input
        var mediaText = inputText
        if inputText.contains("#EXT-X-STREAM-INF") {
            let rungs = StreamProbe.variants(in: inputText, base: input)
            guard let best = rungs.max(by: { $0.bps < $1.bps }) else { throw Failure.invalidPlaylist }
            mediaURL = best.url
            mediaText = try await text(best.url)
        }
        guard mediaText.contains("#EXTINF") else { throw Failure.invalidPlaylist }

        let video = rewrite(mediaText, base: mediaURL, prefix: "v")
        guard video.segments > 0 else { throw Failure.noSegments }
        var jobs = video.jobs

        // A separate audio playlist, when the save sheet picked one. A link
        // that no longer answers drops the audio rather than the whole save.
        var audio: Rewritten?
        if let audioURL = entry.audioURL.flatMap(URL.init(string:)),
           let audioText = try? await text(audioURL), audioText.contains("#EXTINF") {
            let parsed = rewrite(audioText, base: audioURL, prefix: "a")
            if parsed.segments > 0 { audio = parsed; jobs += parsed.jobs }
        }

        try await keepOrWipe(jobs: jobs, seconds: video.seconds)
        try await fetch(jobs)

        if let audio {
            // Video and audio stay two playlists, as the site served them,
            // tied together by a master the player reads as one stream.
            try video.lines.joined(separator: "\n")
                .write(to: folder.appendingPathComponent("video.m3u8"), atomically: true, encoding: .utf8)
            try audio.lines.joined(separator: "\n")
                .write(to: folder.appendingPathComponent("audio.m3u8"), atomically: true, encoding: .utf8)
            let name = (entry.audioLabel ?? "Audio").replacingOccurrences(of: "\"", with: "")
            let master = [
                "#EXTM3U",
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(name)\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
                "#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO=\"aud\"",
                "video.m3u8",
            ]
            try master.joined(separator: "\n")
                .write(to: folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
        } else {
            try video.lines.joined(separator: "\n")
                .write(to: folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
        }

        let subtitle = await saveSubtitle()
        return Outcome(
            relativePath: entry.id.uuidString + "/index.m3u8",
            size: Self.folderSize(folder), duration: video.seconds, subtitlePath: subtitle
        )
    }

    // MARK: subtitles

    private static let sidecarExtensions: Set<String> = ["vtt", "srt", "ass", "ssa", "ttml", "dfxp"]

    /// A chosen subtitle as a file beside the video, or nil. Never fails the
    /// download: a missing subtitle is a smaller loss than a missing video.
    ///
    /// Two shapes, as on Android: a plain .vtt/.srt is the subtitle already,
    /// and kept under its own extension because the player picks its parser by
    /// it; a playlist of cue segments is concatenated into one .vtt.
    private func saveSubtitle() async -> String? {
        guard let url = entry.subtitleURL.flatMap(URL.init(string:)),
              let body = try? await text(url), !body.isEmpty else { return nil }
        let name: String
        let contents: String
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            let e = url.pathExtension.lowercased()
            name = "subtitle." + (Self.sidecarExtensions.contains(e) ? e : "vtt")
            contents = body
        } else {
            var merged = ""
            for raw in body.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"),
                      let segment = URL(string: line, relativeTo: url)?.absoluteURL,
                      let part = try? await text(segment) else { continue }
                if merged.isEmpty {
                    merged = part
                } else {
                    // Each segment repeats the file header; the cues follow the
                    // first blank line.
                    let cues = part.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
                    merged += "\n\n" + cues
                }
            }
            guard !merged.isEmpty else { return nil }
            name = "subtitle.vtt"
            contents = merged
        }
        do {
            try contents.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return entry.id.uuidString + "/" + name
        } catch {
            return nil
        }
    }

    /// Before continuing over parts from an earlier run: is this the same
    /// video? Same segment count, same running time, and the first segment the
    /// same size as the one on disk — else the old parts go and it starts clean.
    private func keepOrWipe(jobs: [Job], seconds: Double) async throws {
        let marker = folder.appendingPathComponent("v.fingerprint")
        let print = "\(jobs.count):\(Int(seconds))"
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: folder.path))?
            .filter { ($0.hasPrefix("v") || $0.hasPrefix("a")) && $0 != "v.fingerprint" && !$0.hasSuffix(".m3u8") } ?? []
        var same = (try? String(contentsOf: marker, encoding: .utf8)) == print
        if same, let first = jobs.first(where: { $0.name.hasPrefix("v0") }) {
            let local = folder.appendingPathComponent(first.name)
            if let size = (try? fm.attributesOfItem(atPath: local.path))?[.size] as? Int64 {
                same = (try await remoteLength(first)) == size
            }
        }
        if !same {
            for name in existing { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        }
        try print.write(to: marker, atomically: true, encoding: .utf8)
    }

    private func fetch(_ jobs: [Job]) async throws {
        let total = Int64(jobs.count)
        let counter = Counter()
        onProgress(0, total)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = jobs.makeIterator()
            func next() -> Job? { iterator.next() }
            for _ in 0..<Self.parallelism {
                guard let job = next() else { break }
                group.addTask { try await self.save(job); self.onProgress(await counter.bump(), total) }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                guard let job = next() else { continue }
                group.addTask { try await self.save(job); self.onProgress(await counter.bump(), total) }
            }
        }
    }

    private actor Counter {
        var value: Int64 = 0
        func bump() -> Int64 { value += 1; return value }
    }

    /// One segment, retried; written to `.part` and renamed, so a run killed
    /// mid-segment never leaves a truncated file that resume would accept.
    private func save(_ job: Job) async throws {
        let target = folder.appendingPathComponent(job.name)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int64, size > 0 { return }
        var lastError: Error = Failure.http(0)
        for attempt in 0..<Self.retries {
            try Task.checkCancellation()
            do {
                var request = request(job.url)
                if let range = job.range { request.setValue(range, forHTTPHeaderField: "Range") }
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw Failure.http(status) }
                let part = target.appendingPathExtension("part")
                try data.write(to: part)
                try? fm.removeItem(at: target)
                try fm.moveItem(at: part, to: target)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as Failure {
                lastError = error
                // A refusal will not change on retry.
                if Self.isLinkDead(error) { throw error }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
        }
        throw lastError
    }

    private func remoteLength(_ job: Job) async throws -> Int64? {
        var request = request(job.url)
        request.httpMethod = "HEAD"
        if let range = job.range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    // MARK: a single file

    /// Continues a partial file with a Range request. The total recorded by the
    /// first run must match the new one, or a fresh link to a different file
    /// restarts from nothing.
    private func saveFile(_ url: URL) async throws -> Outcome {
        let target = folder.appendingPathComponent("video")
        let sizeMarker = folder.appendingPathComponent("video.size")
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path) { fm.createFile(atPath: target.path, contents: nil) }
        let have = ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int64) ?? 0

        var request = request(url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }

        let resumed = http.statusCode == 206
        let total: Int64? = (http.value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last.flatMap { Int64($0) })
            ?? (resumed ? nil : (http.expectedContentLength > 0 ? http.expectedContentLength : nil))
        let recorded = (try? String(contentsOf: sizeMarker, encoding: .utf8)).flatMap { Int64($0) }
        if resumed, let recorded, let total, recorded != total {
            try? fm.removeItem(at: target)
            try? fm.removeItem(at: sizeMarker)
            return try await saveFile(url)
        }
        if let total { try String(total).write(to: sizeMarker, atomically: true, encoding: .utf8) }

        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var written: Int64
        if resumed {
            try handle.seekToEnd()
            written = have
        } else {
            try handle.truncate(atOffset: 0)
            written = 0
        }
        let size = total ?? -1
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReport = written
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if written - lastReport >= 512 * 1024 { lastReport = written; onProgress(written, size) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
        onProgress(written, size > 0 ? size : written)
        return Outcome(relativePath: entry.id.uuidString + "/video", size: written, duration: 0)
    }

    // MARK: helpers

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (name, value) in entry.headers where !value.isEmpty {
            let key = name.lowercased()
            guard key != "range", key != "host", key != "content-length" else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func text(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(for: request(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: name + "=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// `#EXT-X-BYTERANGE` ("len" or "len@offset") as a Range header, and where
    /// a following range with no offset continues from.
    private static func byteRange(_ spec: String?, from continuation: Int64) -> (header: String, next: Int64)? {
        guard let spec, !spec.isEmpty else { return nil }
        let parts = spec.split(separator: "@")
        guard let length = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let offset = parts.count > 1 ? Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? continuation : continuation
        return ("bytes=\(offset)-\(offset + length - 1)", offset + length)
    }

    private static func ext(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        let usable = (1...4).contains(e.count) && e.allSatisfy { $0.isLetter || $0.isNumber }
        return usable ? e : "ts"
    }

    static func folderSize(_ url: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
