import Foundation

/// One timed line of a subtitle file.
struct SubtitleCue: Hashable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

/// The cues of one file, sorted, with a lookup cheap enough to run ten times a
/// second for the whole of a film.
struct SubtitleTimeline: Sendable {
    let cues: [SubtitleCue]

    init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    /// Every cue on screen at `time`, in the order they started.
    ///
    /// Not "the" cue: real files overlap — two speakers at once, a sign over
    /// dialogue — and showing only the latest would drop a line people are
    /// still reading.
    func text(at time: Double) -> String? {
        guard !cues.isEmpty else { return nil }

        // Last cue that has started.
        var low = 0, high = cues.count - 1, last = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { last = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard last >= 0 else { return nil }

        // Walk back a bounded distance for earlier cues still running. An
        // overlap that outlasts thirty-two later cues does not happen in real
        // files, and an unbounded walk would make every lookup linear.
        var active: [String] = []
        var i = last
        while i >= 0, last - i < 32 {
            if cues[i].end > time { active.append(cues[i].text) }
            i -= 1
        }
        guard !active.isEmpty else { return nil }
        return active.reversed().joined(separator: "\n")
    }
}

/// SRT, WebVTT, ASS/SSA and TTML/DFXP — the formats the page sniffer reports —
/// into plain timed text.
///
/// Plain on purpose. ASS positioning, karaoke and per-line fonts would need a
/// renderer of their own (libass, and its size); lines are drawn in the look
/// set in Settings → Subtitles instead, which is also what that screen promises.
enum SubtitleParser {
    static func cues(from data: Data, encoding: String) -> [SubtitleCue] {
        guard let text = decode(data, preferred: encoding) else { return [] }
        return parse(text)
    }

    // MARK: decoding

    /// A byte-order mark is proof and wins. After that the user's chosen
    /// encoding, then UTF-8, then Windows-1252 — which never fails, so the worst
    /// case is visible mojibake the encoding setting can fix, not a blank screen.
    static func decode(_ data: Data, preferred: String) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if !preferred.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(preferred as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }

    // MARK: format detection

    static func parse(_ raw: String) -> [SubtitleCue] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let head = text.prefix(512).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("WEBVTT") { return parseTimedBlocks(text) }
        if head.hasPrefix("[Script Info]") || text.contains("[Events]") || text.contains("\nDialogue:") {
            return parseASS(text)
        }
        if head.hasPrefix("<"), text.contains("<tt") || text.contains("<p") {
            return parseTTML(text)
        }
        return parseTimedBlocks(text)
    }

    // MARK: SRT and WebVTT

    /// Both are blocks of "start --> end" followed by text, so one reader does
    /// both. VTT's header, NOTE and STYLE blocks carry no arrow and are skipped
    /// by construction; so is SRT's counter line.
    private static func parseTimedBlocks(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let arrow = line.range(of: "-->") else { i += 1; continue }
            let startRaw = String(line[..<arrow.lowerBound])
            // VTT puts cue settings after the end time: "00:01.000 line:90%".
            let endRaw = line[arrow.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init) ?? ""
            i += 1

            var body: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                // A file that forgets the blank line runs straight into the next
                // timing line; stop there rather than swallowing the next cue.
                if lines[i].contains("-->") { break }
                body.append(lines[i])
                i += 1
            }

            guard let start = seconds(startRaw), let end = seconds(endRaw), end > start else { continue }
            let cleaned = clean(body.joined(separator: "\n"))
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
        }
        return cues
    }

    // MARK: ASS / SSA

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        // The format line names the columns; this is the standard order, used
        // when a file leaves it out.
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = !text.contains("[Events]")
        var cues: [SubtitleCue] = []

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.hasPrefix("[") {
                inEvents = lower == "[events]"
                continue
            }
            guard inEvents else { continue }

            if lower.hasPrefix("format:") {
                fields = line.dropFirst(7)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard lower.hasPrefix("dialogue:") else { continue }

            // Text is the last column and may itself contain commas.
            let values = line.dropFirst(9).split(
                separator: ",",
                maxSplits: max(0, fields.count - 1),
                omittingEmptySubsequences: false
            )
            func column(_ name: String) -> String? {
                guard let index = fields.firstIndex(of: name), index < values.count else { return nil }
                return String(values[index])
            }
            guard let startRaw = column("start"), let endRaw = column("end"), let body = column("text"),
                  let start = seconds(startRaw), let end = seconds(endRaw), end > start
            else { continue }

            let unescaped = body
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
            let cleaned = clean(unescaped)
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
        }
        return cues
    }

    // MARK: TTML / DFXP

    private static func parseTTML(_ text: String) -> [SubtitleCue] {
        guard let paragraph = try? NSRegularExpression(
            pattern: "<p\\b([^>]*)>(.*?)</p>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }

        let ns = text as NSString
        var cues: [SubtitleCue] = []
        for match in paragraph.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let attributes = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            guard let begin = attribute("begin", in: attributes).flatMap(ttmlSeconds) else { continue }
            let end = attribute("end", in: attributes).flatMap(ttmlSeconds)
                ?? attribute("dur", in: attributes).flatMap(ttmlSeconds).map { begin + $0 }
            guard let end, end > begin else { continue }
            let cleaned = clean(body)
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: begin, end: end, text: cleaned)) }
        }
        return cues
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b" + name + "\\s*=\\s*[\"']([^\"']*)[\"']"
        ) else { return nil }
        let ns = attributes as NSString
        guard let match = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    /// "00:00:01.500" · "00:00:01:12" (frames) · "1.5s" · "1500ms" · "15000000t".
    private static func ttmlSeconds(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("ms"), let v = Double(s.dropLast(2)) { return v / 1000 }
        if s.hasSuffix("s"), let v = Double(s.dropLast()) { return v }
        if s.hasSuffix("t"), let v = Double(s.dropLast()) { return v / 10_000_000 }
        let parts = s.split(separator: ":")
        if parts.count == 4,
           let h = Double(parts[0]), let m = Double(parts[1]),
           let sec = Double(parts[2]), let frames = Double(parts[3]) {
            // The frame rate lives in the document head; 25 is the common
            // default, and a frame's error is 40 ms.
            return h * 3600 + m * 60 + sec + frames / 25
        }
        return seconds(s)
    }

    // MARK: shared

    /// "01:02:03,456" (SRT) · "01:02:03.456" / "02:03.456" (VTT) ·
    /// "1:02:03.45" (ASS) · "12.5".
    static func seconds(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":")
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Markup out, entities decoded, blank lines dropped.
    private static func clean(_ text: String) -> String {
        var s = text
        // ASS override blocks, which SRT files borrow too: {\an8}, {\i1}.
        s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // <i>, <font color=…>, VTT's <c.yellow> and <00:01.000> timestamps.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
        ] {
            s = s.replacingOccurrences(of: entity, with: value)
        }
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
