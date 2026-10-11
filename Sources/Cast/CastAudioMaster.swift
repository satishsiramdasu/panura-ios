import Foundation

/// One audio rendition declared by an HLS master playlist.
struct HLSAudioRendition: Identifiable, Hashable {
    /// Its position among the master's `TYPE=AUDIO` entries, which is also how
    /// `CastAudioMaster.singleAudio` is told which one to keep.
    let id: Int
    let name: String
    /// The `LANGUAGE` attribute, an ISO code — `tel`, `tam`, `en`.
    let language: String?
    let isDefault: Bool

    var label: String {
        guard !name.isEmpty else { return language ?? "Audio \(id + 1)" }
        return name
    }
}

/// Makes a multi-audio HLS stream playable on a Chromecast, by handing the
/// receiver a master playlist that declares one audio track instead of five.
///
/// **The problem is the device, not the playlist.** A Chromecast plays
/// single-audio HLS without complaint; give it a master with alternate audio
/// renditions — video-only variants plus separate audio-only playlists — and
/// it needs two media pipelines running in step, which the Chromecast built
/// into a 2016 Android TV does not have. These are precisely the televisions
/// this feature is for: too old to install Panura's own receiver, and the only
/// way to reach them is the Cast protocol.
///
/// **Which is why this is not fixed in the receiver.** A custom receiver can
/// pick an `activeTrackId` and nothing more; no JavaScript on the television
/// adds a second audio pipeline to hardware that lacks one. Filtering the
/// master turns a stream that fails into a stream of the shape that already
/// works, and it works on every receiver rather than only on one we deploy.
///
/// **The phone serves one kilobyte and then gets out of the way.** Only the
/// master is rewritten and served locally; every variant, rendition and
/// segment URI in it is made absolute, so the television streams from the CDN
/// exactly as it does today, with the same headers the receiver already
/// re-injects. Nothing is proxied, nothing is transcoded, and a dropped Wi-Fi
/// on the phone does not stall the film.
enum CastAudioMaster {
    /// Rewrites `item` for the Cast path if — and only if — it is an HLS
    /// master with more than one audio rendition. nil means send it as it is.
    ///
    /// Every failure returns nil rather than an error: a stream that cannot be
    /// read here is a stream that may still play on the television, and
    /// refusing to cast it because this optimisation could not run would be
    /// worse than the bug it fixes.
    @MainActor
    static func prepare(_ item: MediaItem) async -> MediaItem? {
        guard looksLikeHLS(item),
              let master = await fetch(item),
              master.contains("#EXT-X-STREAM-INF")
        else { return nil }

        let found = renditions(in: master)
        guard found.count > 1 else { return nil }

        guard let keep = preferred(among: found) else { return nil }
        let filtered = singleAudio(master, base: item.url, keeping: keep.id)
        guard PanuraCastManager.shared.startServerForMaster(filtered, base: item.url),
              let address = PanuraCastServer.proxyURL(for: item.url),
              let local = URL(string: address)
        else { return nil }

        var copy = item
        copy.url = local
        // The local address ends `.m3u8`, but say it anyway: the Cast MIME type
        // is chosen from this first and a wrong guess is a refused load.
        copy.contentType = "hls"
        return copy
    }

    // MARK: reading

    static func looksLikeHLS(_ item: MediaItem) -> Bool {
        guard !item.isLocal else { return false }
        if item.contentType?.lowercased() == "hls" { return true }
        return item.url.path.lowercased().hasSuffix(".m3u8")
    }

    /// Fetched with `castHeaders`, not `headers` — the television's set. The
    /// master has to be read on the same terms the television would read the
    /// rest, or a gate that lets us in rejects it.
    private static func fetch(_ item: MediaItem) async -> String? {
        guard let response = await ProbeHTTP.get(
            item.url,
            headers: item.castHeaders,
            limit: 1_000_000
        ) else { return nil }
        guard let text = String(data: response.data, encoding: .utf8),
              text.contains("#EXTM3U")
        else { return nil }
        return text
    }

    /// The audio renditions a master declares, in the order it declares them.
    static func renditions(in master: String) -> [HLSAudioRendition] {
        var found: [HLSAudioRendition] = []
        for raw in master.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-MEDIA:"),
                  attribute("TYPE", in: line) == "AUDIO"
            else { continue }
            found.append(
                HLSAudioRendition(
                    id: found.count,
                    name: attribute("NAME", in: line) ?? "",
                    language: attribute("LANGUAGE", in: line),
                    isDefault: attribute("DEFAULT", in: line) == "YES"
                )
            )
        }
        return found
    }

    /// Which track to send: the language chosen in the player's settings, then
    /// whatever the stream itself marks `DEFAULT`, then the first.
    ///
    /// The setting is shared with the player on purpose. Somebody who has told
    /// this app they want Telugu has told it once, and being asked again at the
    /// television — with a remote in the other hand — is the question they
    /// already answered.
    static func preferred(among found: [HLSAudioRendition]) -> HLSAudioRendition? {
        let wanted = (UserDefaults.standard.string(forKey: "preferred_audio_language") ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if !wanted.isEmpty {
            // Prefix, not equality: a playlist may say `tel`, `te` or `tel-IN`
            // for the same language, and the setting is one of those three.
            if let match = found.first(where: {
                guard let code = $0.language?.lowercased() else { return false }
                return code.hasPrefix(wanted) || wanted.hasPrefix(code)
            }) {
                return match
            }
            if let named = found.first(where: { $0.label.lowercased() == wanted }) {
                return named
            }
        }
        return found.first(where: \.isDefault) ?? found.first
    }

    // MARK: writing

    /// A master declaring exactly one audio rendition, with every URI absolute.
    ///
    /// Variants are all kept, so the television still picks its own bitrate.
    /// Subtitle renditions are kept too — they are a separate pipeline the
    /// receiver handles perfectly well, and dropping them would take captions
    /// away to fix an audio problem.
    ///
    /// `#EXT-X-IMAGE-STREAM-INF` is dropped. It is Roku's trick-play
    /// extension, no Cast receiver reads it, and a line naming a JPEG stream in
    /// a playlist a strict parser is already struggling with is one risk for no
    /// benefit.
    static func singleAudio(_ master: String, base: URL, keeping id: Int) -> String {
        var audioSeen = -1
        var out: [String] = []

        for raw in master.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MEDIA:"), attribute("TYPE", in: line) == "AUDIO" {
                audioSeen += 1
                guard audioSeen == id else { continue }
                out.append(absolutised(makeDefault(line), base: base))
                continue
            }
            if line.hasPrefix("#EXT-X-IMAGE-STREAM-INF") { continue }
            if line.hasPrefix("#") {
                out.append(absolutised(line, base: base))
                continue
            }
            out.append(URL(string: line, relativeTo: base)?.absoluteString ?? line)
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The one surviving rendition has to be the default, whatever it was
    /// before: it is the only thing in its group now, and a group whose sole
    /// member is `DEFAULT=NO` is a receiver's excuse to play no audio at all.
    private static func makeDefault(_ line: String) -> String {
        var out = line
            .replacingOccurrences(of: "DEFAULT=NO", with: "DEFAULT=YES")
            .replacingOccurrences(of: "AUTOSELECT=NO", with: "AUTOSELECT=YES")
        if !out.contains("DEFAULT=") { out += ",DEFAULT=YES" }
        if !out.contains("AUTOSELECT=") { out += ",AUTOSELECT=YES" }
        return out
    }

    /// Absolutises a `URI="…"` attribute against the master's own address.
    ///
    /// Required, not tidy: the television fetches this playlist from a phone,
    /// so a relative URI resolves against the phone — which serves one file and
    /// 404s everything else.
    private static func absolutised(_ line: String, base: URL) -> String {
        guard let start = line.range(of: "URI=\"") else { return line }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return line }
        let uri = String(rest[..<end])
        guard !uri.isEmpty,
              let absolute = URL(string: uri, relativeTo: base)?.absoluteURL
        else { return line }
        return line.replacingOccurrences(
            of: "URI=\"\(uri)\"",
            with: "URI=\"\(absolute.absoluteString)\""
        )
    }

    /// Reads one attribute off a playlist tag, quoted or bare.
    private static func attribute(_ key: String, in line: String) -> String? {
        guard let start = line.range(of: key + "=") else { return nil }
        var rest = line[start.upperBound...]
        if rest.first == "\"" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        return String(rest[..<end])
    }
}
