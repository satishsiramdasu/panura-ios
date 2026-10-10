import SwiftUI
import UIKit

/// Chapters and scrub thumbnails, read out of an HLS master playlist.
///
/// Two things a good stream carries that neither player engine will give you:
///
/// - **Chapters.** `#EXT-X-SESSION-DATA:DATA-ID="com.apple.hls.chapters"` points
///   at a JSON array. It is Apple's own convention, and AVFoundation still does
///   not surface it — so it is fetched here, which has the happy result that
///   VLC gets chapters too.
/// - **Scrub thumbnails.** `#EXT-X-IMAGE-STREAM-INF` points at an images-only
///   playlist of JPEG sprite sheets. This is the Roku trick-play extension, not
///   Apple's `EXT-X-I-FRAME-STREAM-INF`, and **neither AVPlayer nor VLC
///   supports it**. Sheets are fetched, cached and cropped here.
///
/// Both are best-effort and entirely optional. A stream without them loses
/// nothing; a stream with them gets a preview under the thumb and the name of
/// the part being skipped.
@MainActor
final class HLSExtras: ObservableObject {
    struct Chapter: Identifiable, Hashable {
        var id: Double { start }
        let start: Double
        let title: String
    }

    @Published private(set) var chapters: [Chapter] = []
    /// The tile under the thumb, or nil — because there are none, or because
    /// its sheet has not arrived yet.
    @Published private(set) var preview: UIImage?
    var hasPreviews: Bool { trickPlay != nil }

    private var trickPlay: TrickPlay?
    private var sheets = NSCache<NSURL, UIImage>()
    private var fetching: Set<URL> = []
    private var loaded: URL?

    // MARK: loading

    /// Reads the master playlist and follows whichever of the two tags it has.
    ///
    /// Silent about everything. A live channel, an MP4 and a playlist with
    /// neither tag all end the same way: nothing to show, nothing said.
    func load(_ item: MediaItem) async {
        guard loaded != item.url else { return }
        loaded = item.url
        chapters = []
        trickPlay = nil
        preview = nil

        guard let text = await Self.text(item.url, headers: item.headers, limit: 65_535),
              text.contains("#EXTM3U")
        else { return }

        if let uri = Self.attribute("URI", in: Self.line(containing: "com.apple.hls.chapters", in: text)),
           let url = URL(string: uri, relativeTo: item.url)?.absoluteURL {
            await loadChapters(url, headers: item.headers)
        }

        if let uri = Self.attribute("URI", in: Self.line(containing: "#EXT-X-IMAGE-STREAM-INF", in: text)),
           let url = URL(string: uri, relativeTo: item.url)?.absoluteURL,
           // 2 MB is generous for a list of sprite names and small enough that
           // pointing this at the wrong thing costs nothing.
           let playlist = await Self.text(url, headers: item.headers, limit: 2_000_000) {
            trickPlay = TrickPlay(playlist, base: url)
        }
    }

    private func loadChapters(_ url: URL, headers: [String: String]) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return }

        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        var found: [Chapter] = []
        for row in rows {
            guard let start = Self.seconds(row["start-time"]) else { continue }
            // `titles` is an array of {language, title}. A chapter with no
            // usable title still earns a row — the position is the point.
            let titles = row["titles"] as? [[String: Any]] ?? []
            let title = titles.first { ($0["language"] as? String) == preferred }?["title"] as? String
                ?? titles.first?["title"] as? String
                ?? row["title"] as? String
                ?? "Chapter \(found.count + 1)"
            found.append(Chapter(start: start, title: title))
        }
        // No `duration` in the wild — this provider omits it entirely — so a
        // chapter runs until the next one starts. Sorted because nothing says
        // the file is.
        chapters = found.sorted { $0.start < $1.start }
    }

    // MARK: asking

    /// The chapter covering this moment.
    func chapter(at seconds: Double) -> Chapter? {
        guard !chapters.isEmpty else { return nil }
        return chapters.last { $0.start <= seconds } ?? chapters.first
    }

    /// Updates `preview` for this moment, fetching the sheet if it is not here.
    ///
    /// Deliberately not `async`: it is called from a slider's setter, dozens of
    /// times a second. It answers from cache or it answers nothing and goes to
    /// fetch, and the next call after the sheet lands shows it.
    func requestPreview(at seconds: Double) {
        guard let trickPlay, let tile = trickPlay.tile(at: seconds) else {
            if preview != nil { preview = nil }
            return
        }
        guard let sheet = sheets.object(forKey: tile.sheet as NSURL) else {
            fetchSheet(tile.sheet)
            return
        }
        preview = Self.crop(sheet, tile: tile)
    }

    func clearPreview() { preview = nil }

    private func fetchSheet(_ url: URL) {
        guard !fetching.contains(url) else { return }
        fetching.insert(url)
        Task { [weak self] in
            defer { Task { @MainActor in self?.fetching.remove(url) } }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
            else { return }
            await MainActor.run { self?.sheets.setObject(image, forKey: url as NSURL) }
        }
    }

    /// Cuts one tile out of a sheet.
    ///
    /// The tile size is taken from the image rather than from the playlist's
    /// `RESOLUTION`, which describes what the provider meant rather than what
    /// the file turned out to be — a sheet served at 2× would otherwise be
    /// cropped to a quarter of one tile.
    private static func crop(_ sheet: UIImage, tile: TrickPlay.Tile) -> UIImage? {
        guard let cgImage = sheet.cgImage else { return nil }
        let width = CGFloat(cgImage.width) / CGFloat(tile.columns)
        let height = CGFloat(cgImage.height) / CGFloat(tile.rows)
        let rect = CGRect(
            x: width * CGFloat(tile.index % tile.columns),
            y: height * CGFloat(tile.index / tile.columns),
            width: width,
            height: height
        )
        guard let cropped = cgImage.cropping(to: rect.integral) else { return nil }
        return UIImage(cgImage: cropped, scale: sheet.scale, orientation: sheet.imageOrientation)
    }

    // MARK: reading playlists

    private static func text(_ url: URL, headers: [String: String], limit: Int) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(limit)", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func line(containing needle: String, in text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first { $0.contains(needle) }.map(String.init)
    }

    nonisolated static func attribute(_ key: String, in line: String?) -> String? {
        guard let line, let range = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Unquoted attribute, for `LAYOUT=5x4` and `DURATION=10.000`.
    ///
    /// `nonisolated`, along with `attribute` above, because `TrickPlay` parses
    /// a playlist in its own initialiser and is not an actor's business — this
    /// class is `@MainActor` for its published state, and string reading has
    /// nothing to do with that.
    nonisolated static func value(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let rest = line[range.upperBound...]
        let end = rest.firstIndex { $0 == "," } ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func seconds(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }
}

/// An images-only playlist: sprite sheets, each a grid of stills.
///
///     #EXT-X-TILES:RESOLUTION=160x90,LAYOUT=5x4,DURATION=10.000
///     #EXTINF:200.000,
///     sprite_001.jpg
///
/// Five columns by four rows is twenty tiles at ten seconds each, which is the
/// two hundred seconds the `#EXTINF` claims — the two numbers are independent
/// and agreeing, which is the check worth making when one of them is wrong.
struct TrickPlay {
    struct Sheet {
        let url: URL
        let start: Double
        let duration: Double
        let columns: Int
        let rows: Int
        let tileSeconds: Double
    }

    struct Tile {
        let sheet: URL
        let index: Int
        let columns: Int
        let rows: Int
    }

    private let sheets: [Sheet]

    init?(_ text: String, base: URL) {
        guard text.contains("#EXT-X-IMAGES-ONLY") || text.contains("#EXT-X-TILES") else { return nil }

        var found: [Sheet] = []
        var clock: Double = 0
        var layout: (columns: Int, rows: Int, tile: Double)?
        var span: Double?

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-TILES") {
                let grid = (HLSExtras.value("LAYOUT", in: line) ?? "").split(separator: "x")
                guard grid.count == 2,
                      let columns = Int(grid[0]), let rows = Int(grid[1]),
                      let tile = Double(HLSExtras.value("DURATION", in: line) ?? "")
                else { continue }
                layout = (columns, rows, tile)
            } else if line.hasPrefix("#EXTINF") {
                span = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
            } else if line.hasPrefix("#") || line.isEmpty {
                continue
            } else if let layout, let duration = span,
                      let url = URL(string: line, relativeTo: base)?.absoluteURL {
                found.append(
                    Sheet(
                        url: url, start: clock, duration: duration,
                        columns: layout.columns, rows: layout.rows,
                        tileSeconds: layout.tile
                    )
                )
                clock += duration
                span = nil
            }
        }
        // The last tag pair in a playlist is routinely left dangling with no
        // image after it, which is why the URI is what commits a sheet rather
        // than the tag that describes one.
        guard !found.isEmpty else { return nil }
        sheets = found
    }

    func tile(at seconds: Double) -> Tile? {
        guard let sheet = sheets.last(where: { $0.start <= seconds }) ?? sheets.first else {
            return nil
        }
        let within = max(0, seconds - sheet.start)
        let last = sheet.columns * sheet.rows - 1
        let index = min(last, max(0, Int(within / max(0.001, sheet.tileSeconds))))
        return Tile(sheet: sheet.url, index: index, columns: sheet.columns, rows: sheet.rows)
    }
}

/// What the thumb is over: the still, and the part of the programme it is in.
struct ScrubPreview: View {
    let image: UIImage?
    let chapter: String?
    let time: String

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 160, height: 90)
            }
            VStack(spacing: 1) {
                if let chapter, !chapter.isEmpty {
                    Text(chapter)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                Text(time).font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .transition(.opacity)
    }
}
