import Foundation

/// One entry of an M3U playlist.
struct M3UChannel: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let group: String?
    let logo: URL?
}

/// A loaded playlist and where it came from.
struct M3UPlaylist {
    let sourceURL: String
    let channels: [M3UChannel]

    var groups: [String] {
        var seen: [String] = []
        for channel in channels {
            if let group = channel.group, !group.isEmpty, !seen.contains(group) {
                seen.append(group)
            }
        }
        return seen
    }
}

/// The Network Stream tab's state: what was typed, what was played before, and
/// the playlist behind a URL that turned out to hold one.
///
/// Mirrors Android's `NetworkStreamViewModel` — including the part that matters
/// most in practice: an `.m3u` is usually a *list*, and playing it as a single
/// stream gives you whichever channel happens to be first.
@MainActor
final class StreamModel: ObservableObject {
    @Published var history: [String] = []
    @Published var playlist: M3UPlaylist?
    @Published var isLoading = false
    @Published var error: String?

    private let historyKey = "stream_history"
    private let historyLimit = 20

    init() {
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    func remember(_ url: String) {
        history.removeAll { $0 == url }
        history.insert(url, at: 0)
        if history.count > historyLimit { history = Array(history.prefix(historyLimit)) }
        persist()
    }

    func remove(_ url: String) {
        history.removeAll { $0 == url }
        persist()
    }

    func clearHistory() {
        history = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(history, forKey: historyKey)
    }

    /// Fetches a URL that looks like a playlist and parses it. Returns false
    /// when the body is not one, which is the caller's cue to play the URL as an
    /// ordinary stream — a `.m3u8` is both a playlist format and a stream, and
    /// only the body can tell the two apart.
    func loadPlaylistIfAny(_ url: URL, headers: [String: String]) async -> Bool {
        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (name, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            error = "Couldn't reach that address."
            return false
        }

        let text = String(decoding: data.prefix(2_000_000), as: UTF8.self)
        // #EXT-X-STREAM-INF is HLS: a stream, not a channel list. #EXTINF with
        // no HLS tags around it is the IPTV kind, which is what this handles.
        guard text.contains("#EXTINF"), !text.contains("#EXT-X-STREAM-INF"),
              !text.contains("#EXT-X-TARGETDURATION") else { return false }

        let channels = Self.parse(text, base: url)
        guard channels.count > 1 else { return false }
        playlist = M3UPlaylist(sourceURL: url.absoluteString, channels: channels)
        error = nil
        return true
    }

    func clearPlaylist() { playlist = nil }

    /// `#EXTINF:-1 tvg-logo="…" group-title="News",Channel Name` then the URL on
    /// the following non-comment line.
    static func parse(_ text: String, base: URL) -> [M3UChannel] {
        var channels: [M3UChannel] = []
        var name: String?
        var group: String?
        var logo: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                name = line.components(separatedBy: ",").dropFirst().joined(separator: ",")
                    .trimmingCharacters(in: .whitespaces)
                group = attribute("group-title", in: line)
                logo = attribute("tvg-logo", in: line)
            } else if line.hasPrefix("#") || line.isEmpty {
                continue
            } else if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                channels.append(
                    M3UChannel(
                        name: (name?.isEmpty == false ? name! : url.lastPathComponent),
                        url: url,
                        group: group,
                        logo: logo.flatMap { URL(string: $0) }
                    )
                )
                name = nil; group = nil; logo = nil
            }
        }
        return channels
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }
}
