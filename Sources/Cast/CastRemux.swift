import Foundation

/// Folds a video-only HLS variant and its separate audio playlist into one
/// MPEG-TS stream, on the phone, as the television asks for it.
///
/// **Why this has to exist.** An HLS master that declares `EXT-X-MEDIA
/// TYPE=AUDIO` has no audio in its video segments: the variants carry one
/// elementary stream each and the audio arrives from its own playlist. Playing
/// that needs two media pipelines running in step, and the Chromecast built
/// into an Android 6 or 7 television has one. Those sets are the whole point of
/// the Cast path — too old to install Panura's own receiver, reachable no other
/// way — and on them such a stream loads, shows a frame, and stops.
///
/// `CastAudioMaster` cannot fix it. That one reduces the *number* of audio
/// renditions, which is the right answer to "five languages, one pipeline" and
/// no answer at all to "the audio is not in the video": one rendition is still
/// a second pipeline. The streams this was built for have exactly one.
///
/// So the audio is put back where an old decoder expects it. Nothing is
/// re-encoded — the PES packets are carried across untouched, so the picture
/// and the sound are bit-for-bit what the CDN sent and the phone spends no
/// battery on a transcode. What changes is bookkeeping: both inputs number
/// their one elementary stream `0x100`, so they are renumbered apart, a program
/// map declaring both is written at the head of every segment, and continuity
/// counters are renumbered because the audio is being cut at boundaries the
/// provider never cut it at.
///
/// **The cost, stated plainly:** every byte of the film now travels CDN →
/// phone → television instead of CDN → television. It is the price of the
/// television being too old, which is why this is an option and not a default.
enum CastRemux {

    // MARK: - what a prepared stream knows

    struct Segment {
        let url: URL
        let duration: Double
        /// Seconds from the start of the playlist, accumulated. The audio
        /// window is cut on these, so they have to be exact running sums
        /// rather than re-derived per segment.
        let start: Double
    }

    /// One video rendition of the film, with its own segment list.
    ///
    /// All of them are kept, not just the best. Muxing puts the phone in the
    /// path, and a single hard-coded variant means a link that cannot keep up
    /// has no lower gear to change into — it stalls instead of softening. With
    /// every variant offered the receiver still runs its own bitrate ladder,
    /// exactly as it would against the CDN.
    struct Variant {
        /// The `#EXT-X-STREAM-INF` attributes, with `AUDIO=` removed — there is
        /// no audio group any more, because the audio is in the video.
        let attributes: String
        let segments: [Segment]
        let total: Double
    }

    /// Everything needed to answer the television, for one cast.
    ///
    /// A class, and locked: Swifter answers each connection on its own queue,
    /// so the caches are touched from several threads at once.
    final class Session: @unchecked Sendable {
        let variants: [Variant]
        let audio: [Segment]
        let audioTotal: Double
        /// First audio PTS in the stream, measured once from the first audio
        /// segment. Playlist time plus this is the audio clock.
        let audioOffset: Int64
        /// `#EXT-X-MEDIA TYPE=SUBTITLES` lines from the original master, URIs
        /// made absolute. Subtitles are a text track, not a media pipeline, so
        /// they are no part of this problem and are carried straight through.
        let subtitles: [String]
        let headers: [String: String]
        /// What was being cast, so the control screen can name it and a change
        /// of mind can go back to it.
        let original: MediaItem
        /// Which audio track is muxed in, for the picker.
        let tracks: [HLSAudioRendition]
        let chosen: Int

        private var cache: [String: Data] = [:]
        private var order: [String] = []
        private var inFlight: Set<String> = []
        private let lock = NSLock()

        init(
            variants: [Variant], audio: [Segment], audioTotal: Double,
            audioOffset: Int64, subtitles: [String], headers: [String: String],
            original: MediaItem, tracks: [HLSAudioRendition], chosen: Int
        ) {
            self.variants = variants
            self.audio = audio
            self.audioTotal = audioTotal
            self.audioOffset = audioOffset
            self.subtitles = subtitles
            self.headers = headers
            self.original = original
            self.tracks = tracks
            self.chosen = chosen
        }

        var chosenTrack: HLSAudioRendition? { tracks.first { $0.id == chosen } }

        // MARK: what the television is handed

        /// The master: every variant, pointing back here, and no audio group.
        func master(root: String) -> String {
            var lines = ["#EXTM3U", "#EXT-X-VERSION:3"]
            lines += subtitles
            for (index, variant) in variants.enumerated() {
                lines.append("#EXT-X-STREAM-INF:" + variant.attributes)
                lines.append("\(root)/mux/v\(index).m3u8")
            }
            return lines.joined(separator: "\n") + "\n"
        }

        /// A variant's media playlist: the same durations, our segment URLs.
        func playlist(variant index: Int, root: String) -> String? {
            guard variants.indices.contains(index) else { return nil }
            let variant = variants[index]
            let longest = variant.segments.map(\.duration).max() ?? 10
            var lines = [
                "#EXTM3U",
                "#EXT-X-VERSION:3",
                "#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-PLAYLIST-TYPE:VOD",
            ]
            for (number, segment) in variant.segments.enumerated() {
                lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
                lines.append("\(root)/mux/\(index)-\(number).ts")
            }
            lines.append("#EXT-X-ENDLIST")
            return lines.joined(separator: "\n") + "\n"
        }

        /// One muxed segment. Blocking, because it is answering an HTTP
        /// request on Swifter's queue.
        func segment(variant index: Int, number: Int) -> Data? {
            guard variants.indices.contains(index) else { return nil }
            let variant = variants[index]
            guard variant.segments.indices.contains(number) else { return nil }

            // **The window tiles by construction, and that is the whole
            // point.** Each audio block goes to exactly one segment because
            // this segment's end *is* the next one's start — both read off the
            // same accumulated playlist clock. Deriving the end from this
            // segment's own duration instead looks equivalent and is not: the
            // two boundaries then disagree by a fraction of a block, and every
            // one of the hundreds of segment joins in a film either repeats a
            // piece of audio or drops one.
            let span = window(variant, number)
            guard let pictures = fetch(variant.segments[number].url) else { return nil }
            let sound = audioSegments(overlapping: span).compactMap { fetch($0.url) }
            guard !sound.isEmpty else { return nil }

            // The next one, while the television chews on this. One ahead
            // only: the phone is a cache of last resort, not a CDN.
            if variant.segments.indices.contains(number + 1) {
                prefetch(variant.segments[number + 1].url)
            }
            return TS.mux(video: pictures, audio: sound, keeping: span)
        }

        /// Audio PTS covered by video segment `number`.
        private func window(_ variant: Variant, _ number: Int) -> Range<Int64> {
            let next = number + 1 < variant.segments.count
                ? variant.segments[number + 1].start
                : variant.total
            let lo = audioOffset + Int64((variant.segments[number].start * 90_000).rounded())
            let hi = audioOffset + Int64((next * 90_000).rounded())
            return lo..<max(lo + 1, hi)
        }

        /// Audio segments that could hold anything in `span`, one either side.
        ///
        /// The margin is not caution for its own sake: the window is cut on
        /// the video's playlist clock and the audio is packed on its own, so a
        /// block belonging in this window can sit in a segment whose declared
        /// range does not quite reach it. A neighbour that contributes nothing
        /// costs one cache hit.
        private func audioSegments(overlapping span: Range<Int64>) -> [Segment] {
            let from = Double(span.lowerBound - audioOffset) / 90_000
            let upto = Double(span.upperBound - audioOffset) / 90_000
            var first = audio.count
            var last = -1
            for (index, segment) in audio.enumerated()
            where segment.start < upto && segment.start + segment.duration > from {
                first = min(first, index)
                last = max(last, index)
            }
            guard last >= 0 else { return [] }
            return Array(audio[max(0, first - 1)...min(audio.count - 1, last + 1)])
        }

        // MARK: fetching, with a short memory

        /// Six segments: two or three video and the audio around them — enough
        /// that consecutive video segments sharing an audio segment fetch it
        /// once, small enough to stay a few megabytes.
        private static let keep = 6

        private func cached(_ key: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return cache[key]
        }

        private func store(_ data: Data, for key: String) {
            lock.lock(); defer { lock.unlock() }
            if cache[key] == nil { order.append(key) }
            cache[key] = data
            inFlight.remove(key)
            while order.count > Self.keep {
                cache.removeValue(forKey: order.removeFirst())
            }
        }

        private func fetch(_ url: URL) -> Data? {
            let key = url.absoluteString
            if let hit = cached(key) { return hit }
            guard let data = Self.download(url, headers: headers) else { return nil }
            let stripped = StreamProxy.stripDecoyHeader(data)
            store(stripped, for: key)
            return stripped
        }

        private func prefetch(_ url: URL) {
            let key = url.absoluteString
            lock.lock()
            let skip = cache[key] != nil || inFlight.contains(key)
            if !skip { inFlight.insert(key) }
            lock.unlock()
            guard !skip else { return }
            let headers = headers
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                guard let data = Self.download(url, headers: headers) else {
                    self.lock.lock()
                    self.inFlight.remove(key)
                    self.lock.unlock()
                    return
                }
                self.store(StreamProxy.stripDecoyHeader(data), for: key)
            }
        }

        /// Blocking GET with the television's headers — the same set the
        /// receiver would have sent, so a gate that admits the TV admits us.
        static func download(_ url: URL, headers: [String: String]) -> Data? {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            var out: Data?
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if status < 400 { out = data }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 35)
            return out
        }
    }

    // MARK: - reading the master

    /// Whether muxing would change anything about this master.
    ///
    /// The test is whether audio is declared *separately*, not how much of it
    /// there is. One alternate rendition and five are the same shape and the
    /// same failure; a master with no `EXT-X-MEDIA TYPE=AUDIO` already has its
    /// audio in the video and must be left alone.
    static func isCandidate(_ master: String) -> Bool {
        master.components(separatedBy: .newlines).contains {
            let line = $0.trimmingCharacters(in: .whitespaces).uppercased()
            return line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO")
        }
    }

    /// Whether muxing could help this stream, without preparing it.
    ///
    /// Costs one fetch of about a kilobyte, and is worth paying to decide
    /// whether to offer the option at all: on a stream whose audio is already
    /// inside its video, muxing is a switch that would change nothing, and
    /// offering it there would send somebody chasing the wrong fault.
    static func looksMuxable(_ item: MediaItem) async -> Bool {
        guard CastAudioMaster.looksLikeHLS(item),
              let master = await text(item.url, headers: item.castHeaders)
        else { return false }
        return isCandidate(master)
    }

    /// Reads the master and both halves of the stream. nil if anything rules
    /// muxing out — encrypted segments, fragmented MP4, no variants, an audio
    /// playlist that will not parse.
    static func prepare(_ item: MediaItem, track: Int? = nil) async -> Session? {
        guard CastAudioMaster.looksLikeHLS(item),
              let master = await text(item.url, headers: item.castHeaders),
              isCandidate(master)
        else { return nil }

        let offered = CastAudioMaster.renditions(in: master)
        guard let chosen = pick(offered, track: track),
              let audioURL = URL(string: chosen.uri, relativeTo: item.url)?.absoluteURL,
              let audioText = await text(audioURL, headers: item.castHeaders),
              let audioList = parsePlaylist(audioText, base: audioURL),
              !audioList.segments.isEmpty
        else { return nil }

        var variants: [Variant] = []
        for (attributes, url) in streamInfo(master, base: item.url) {
            guard let body = await text(url, headers: item.castHeaders),
                  let list = parsePlaylist(body, base: url),
                  !list.segments.isEmpty
            else { continue }
            variants.append(Variant(attributes: attributes, segments: list.segments, total: list.total))
        }
        guard !variants.isEmpty else { return nil }

        // One measurement, once: where the audio clock starts. Every window is
        // then arithmetic on the playlist, with nothing more to probe.
        guard let head = await ProbeHTTP.get(
                audioList.segments[0].url, headers: item.castHeaders, limit: 4_000_000
              ),
              let offset = TS.firstPTS(in: [UInt8](StreamProxy.stripDecoyHeader(head.data)))
        else { return nil }

        return Session(
            variants: variants,
            audio: audioList.segments,
            audioTotal: audioList.total,
            audioOffset: offset,
            subtitles: subtitleLines(master, base: item.url),
            headers: item.castHeaders,
            original: item,
            tracks: offered,
            chosen: chosen.id
        )
    }

    /// The track asked for, else the same answer the single-audio path would
    /// give — so turning muxing on does not silently change the language.
    private static func pick(_ offered: [HLSAudioRendition], track: Int?) -> HLSAudioRendition? {
        if let track, let match = offered.first(where: { $0.id == track }) { return match }
        return CastAudioMaster.preferred(among: offered)
    }

    private static func text(_ url: URL, headers: [String: String]) async -> String? {
        guard let response = await ProbeHTTP.get(url, headers: headers, limit: 4_000_000),
              let text = String(data: response.data, encoding: .utf8),
              text.contains("#EXTM3U")
        else { return nil }
        return text
    }

    /// Variants as (attributes without `AUDIO=`, absolute playlist URL).
    private static func streamInfo(_ master: String, base: URL) -> [(String, URL)] {
        var found: [(String, URL)] = []
        var pending: String?
        for raw in master.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = stripAudioGroup(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if let attributes = pending, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    found.append((attributes, url))
                }
                pending = nil
            }
        }
        return found
    }

    /// Removes `AUDIO="group"`. Leaving it would name a group the master no
    /// longer declares, which is a playlist a receiver is entitled to reject.
    private static func stripAudioGroup(_ attributes: String) -> String {
        var out = attributes
        while let start = out.range(of: "AUDIO=\"") {
            guard let quote = out[start.upperBound...].firstIndex(of: "\"") else { break }
            var cut = start.lowerBound..<out.index(after: quote)
            // Take the comma with it, whichever side it is on.
            if cut.upperBound < out.endIndex, out[cut.upperBound] == "," {
                cut = cut.lowerBound..<out.index(after: cut.upperBound)
            } else if cut.lowerBound > out.startIndex,
                      out[out.index(before: cut.lowerBound)] == "," {
                cut = out.index(before: cut.lowerBound)..<cut.upperBound
            }
            out.removeSubrange(cut)
        }
        return out
    }

    private static func subtitleLines(_ master: String, base: URL) -> [String] {
        master.components(separatedBy: .newlines).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("#EXT-X-MEDIA:"),
                  line.uppercased().contains("TYPE=SUBTITLES")
            else { return nil }
            guard let start = line.range(of: "URI=\""),
                  let quote = line[start.upperBound...].firstIndex(of: "\"")
            else { return line }
            let uri = String(line[start.upperBound..<quote])
            guard let absolute = URL(string: uri, relativeTo: base)?.absoluteURL else { return line }
            return line.replacingOccurrences(
                of: "URI=\"\(uri)\"",
                with: "URI=\"\(absolute.absoluteString)\""
            )
        }
    }

    /// A media playlist's segments and its total duration. nil when there is
    /// nothing muxable inside the segments.
    ///
    /// **A live playlist is refused.** What comes back here is a snapshot, and
    /// serving it with fixed segment numbers would hand the television a film
    /// that is a few minutes long and then over — while the channel carries on
    /// without it. Muxing live would mean re-reading both playlists on a timer
    /// and renumbering as segments fall off the front, which is a different
    /// piece of work; until it exists, a channel is better cast the way it is
    /// cast today. `#EXT-X-ENDLIST` is the only reliable sign of a finished
    /// playlist: `PLAYLIST-TYPE` is optional and often absent on VOD.
    static func parsePlaylist(_ text: String, base: URL) -> (segments: [Segment], total: Double)? {
        guard text.contains("#EXT-X-ENDLIST") else { return nil }
        var segments: [Segment] = []
        var duration: Double?
        var clock = 0.0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                duration = Double(value)
            } else if upper.hasPrefix("#EXT-X-KEY:"), !upper.contains("METHOD=NONE") {
                return nil          // encrypted: nothing to take apart
            } else if upper.hasPrefix("#EXT-X-MAP:") {
                return nil          // fragmented MP4, not transport stream
            } else if !line.isEmpty, !line.hasPrefix("#"), let found = duration {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { return nil }
                segments.append(Segment(url: url, duration: found, start: clock))
                clock += found
                duration = nil
            }
        }
        return (segments, clock)
    }
}
