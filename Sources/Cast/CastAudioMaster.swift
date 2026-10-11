import Foundation

/// One audio rendition declared by an HLS master playlist.
struct HLSAudioRendition: Identifiable, Hashable {
    /// Its position among *all* the master's `TYPE=AUDIO` entries, which is how
    /// `CastAudioMaster.singleAudio` is told which one to keep. Positional
    /// rather than named because two renditions can share a language across
    /// groups — "Telugu" and "Telugu 5.1" are the same film twice.
    let id: Int
    /// Its `GROUP-ID`. Variants reference a group, never a rendition, so this
    /// is what decides which variants can survive beside it.
    let group: String
    let name: String
    /// The `LANGUAGE` attribute, an ISO code — `tel`, `tam`, `en`.
    let language: String?
    let isDefault: Bool
    /// Its `URI`, as written in the master — relative or absolute.
    ///
    /// Unused by `singleAudio`, which only ever moves the whole line around.
    /// `CastRemux` needs it: muxing means actually fetching the audio playlist
    /// rather than pointing the television at it.
    let uri: String

    var label: String {
        guard !name.isEmpty else { return language ?? "Audio \(id + 1)" }
        return name
    }
}

/// Makes a multi-audio HLS stream playable on a Chromecast, by handing the
/// receiver a master playlist that declares one audio track instead of six.
///
/// **The problem is the device, not the playlist.** A Chromecast plays
/// single-audio HLS without complaint; give it a master with alternate audio
/// renditions — video-only variants plus separate audio-only playlists — and it
/// needs two media pipelines running in step, which the Chromecast built into a
/// 2016 Android TV does not have. Those are precisely the televisions this is
/// for: too old to install Panura's own receiver, reachable only over Cast.
///
/// **Which is why this is not fixed in the receiver.** A custom receiver can
/// pick an `activeTrackId` and nothing more; no JavaScript on the television
/// adds a second audio pipeline to hardware that lacks one. Filtering the
/// master turns a stream that fails into one of the shape that already works,
/// on every receiver rather than only on one we deploy.
///
/// **A rendition is not enough — the group has to go too.** Real playlists
/// carry more than one audio *group*: a stereo AAC group of five languages and
/// a Dolby group holding the 5.1 mix, with every `EXT-X-STREAM-INF` naming the
/// group it expects. Keeping one rendition and leaving four variants in place,
/// two of them pointing at a group that no longer exists, is a broken playlist
/// rather than a simplified one. So one group survives, and only the variants
/// that reference it.
///
/// **Dolby groups are dropped outright.** `ec-3` and `ac-3` are undecodable on
/// most Cast devices and on essentially every old Android TV built-in, so such
/// a group is never chosen and never offered. A 5.1 mix is not a track somebody
/// can select on a television that cannot play it.
///
/// **The phone serves one kilobyte and then gets out of the way.** Only the
/// master is rewritten and served locally; every URI in it is made absolute, so
/// the television streams from the CDN exactly as it does today, with the same
/// headers the receiver already re-injects. Nothing is proxied, nothing is
/// transcoded, and the phone leaving the network does not stall the film.
enum CastAudioMaster {
    /// A multi-audio stream, reduced to one track and ready for a Chromecast.
    ///
    /// The original item and the untouched master are both kept, because
    /// changing the track later means building a different playlist from the
    /// same source — and by then the thing on the television is our local
    /// address, which names neither.
    struct Prepared: Equatable {
        /// What the receiver is handed.
        let send: MediaItem
        /// The stream as the page gave it to us.
        let original: MediaItem
        /// The master as it was fetched, unfiltered.
        let master: String
        /// The tracks worth offering: the chosen group's, and no other. A
        /// rendition from a group this receiver cannot decode is not a choice,
        /// it is a trap.
        let tracks: [HLSAudioRendition]
        let chosen: Int

        var chosenTrack: HLSAudioRendition? { tracks.first { $0.id == chosen } }
    }

    /// Audio codecs not worth sending to a Cast device. Dolby Digital and
    /// Dolby Digital Plus, in both their HLS and MP4 spellings.
    ///
    /// Licensing, not bandwidth: a television that cannot decode these will not
    /// start, and the stereo mix of the same film is in the same playlist.
    private static let undecodable = ["ec-3", "ac-3", "eac3", "mp4a.a5", "mp4a.a6"]

    // MARK: preparing

    /// Rewrites `item` for the Cast path if — and only if — it is an HLS master
    /// that needs it. nil means send it as it is.
    ///
    /// Every failure returns nil rather than an error: a stream that cannot be
    /// read here may still play on the television, and refusing to cast it
    /// because this rewrite could not run would be worse than the bug it fixes.
    @MainActor
    static func prepare(_ item: MediaItem) async -> Prepared? {
        guard looksLikeHLS(item),
              let master = await fetch(item),
              master.contains("#EXT-X-STREAM-INF"),
              needsRewriting(master)
        else { return nil }

        let all = renditions(in: master)
        guard !all.isEmpty else { return nil }

        let group = chooseGroup(in: master, among: all)
        let offered = all.filter { $0.group == group }
        guard let keep = preferred(among: offered) else { return nil }

        return build(item: item, master: master, tracks: offered, choosing: keep.id)
    }

    /// The same stream with a different audio track, ready to be re-sent.
    @MainActor
    static func reselect(_ prepared: Prepared, to id: Int) -> Prepared? {
        guard prepared.tracks.contains(where: { $0.id == id }) else { return nil }
        return build(
            item: prepared.original,
            master: prepared.master,
            tracks: prepared.tracks,
            choosing: id
        )
    }

    @MainActor
    private static func build(
        item: MediaItem,
        master: String,
        tracks: [HLSAudioRendition],
        choosing id: Int
    ) -> Prepared? {
        let filtered = singleAudio(master, base: item.url, keeping: id)
        // Filtering that removed every variant has produced a playlist with no
        // video in it. Send the original instead: it may well fail, but then it
        // fails the way it did before rather than because of us.
        guard filtered.contains("#EXT-X-STREAM-INF"),
              PanuraCastManager.shared.startServerForMaster(filtered, base: item.url),
              let address = PanuraCastServer.proxyURL(for: item.url),
              // **The track number is in the address on purpose.** Changing
              // audio serves a different playlist at the same path, and a
              // receiver that cached the last one would play the last one. A
              // query string is enough — the server's routes ignore it — and it
              // is the smallest thing that makes two loads different URLs.
              let local = URL(string: address + "?a=\(id)")
        else { return nil }

        var copy = item
        copy.url = local
        // The local address ends `.m3u8` before the query, but say it anyway:
        // the Cast MIME type is chosen from this first and a wrong guess is a
        // refused load.
        copy.contentType = "hls"
        return Prepared(
            send: copy,
            original: item,
            master: master,
            tracks: tracks,
            chosen: id
        )
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

    /// Whether this master is one a Chromecast would struggle with.
    ///
    /// Three reasons, any one enough: more than one audio track, more than one
    /// audio group, or a variant asking for a codec the device cannot decode.
    /// The last two are what a rendition count misses — a playlist with one AAC
    /// language and one Dolby 5.1 mix has "one audio track per group" and still
    /// hands the receiver a variant it will choke on.
    static func needsRewriting(_ master: String) -> Bool {
        let all = renditions(in: master)
        guard !all.isEmpty else { return false }
        if all.count > 1 { return true }
        if Set(all.map(\.group)).count > 1 { return true }
        return variants(in: master).contains { isUndecodable($0.codecs) }
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
                    group: attribute("GROUP-ID", in: line) ?? "",
                    name: attribute("NAME", in: line) ?? "",
                    language: attribute("LANGUAGE", in: line),
                    isDefault: attribute("DEFAULT", in: line) == "YES",
                    uri: attribute("URI", in: line) ?? ""
                )
            )
        }
        return found
    }

    /// Every `EXT-X-STREAM-INF`, reduced to the two attributes that matter
    /// here: which audio group it expects, and what it wants decoded.
    private static func variants(in master: String) -> [(audio: String, codecs: String)] {
        master.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { return nil }
            return (attribute("AUDIO", in: line) ?? "", attribute("CODECS", in: line) ?? "")
        }
    }

    private static func isUndecodable(_ codecs: String) -> Bool {
        let lower = codecs.lowercased()
        return undecodable.contains { lower.contains($0) }
    }

    /// Which audio group to keep.
    ///
    /// A group is usable when some variant referencing it asks for nothing the
    /// receiver cannot decode. Preferred in that order: a usable group holding
    /// the language the player's settings name, then any usable group, then —
    /// if nothing is usable — whatever the first rendition belongs to, so a
    /// Dolby-only playlist is still reduced to one track and fails for its own
    /// reasons rather than ours.
    private static func chooseGroup(
        in master: String,
        among all: [HLSAudioRendition]
    ) -> String {
        let usable = Set(
            variants(in: master).filter { !isUndecodable($0.codecs) }.map(\.audio)
        )
        let groups = all.map(\.group)

        if !usable.isEmpty {
            let wanted = preferredLanguage
            if !wanted.isEmpty,
               let match = all.first(where: { usable.contains($0.group) && matches($0, wanted) }) {
                return match.group
            }
            if let first = groups.first(where: { usable.contains($0) }) { return first }
        }
        return groups.first ?? ""
    }

    private static var preferredLanguage: String {
        (UserDefaults.standard.string(forKey: "preferred_audio_language") ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Prefix matching, not equality: a playlist may say `tel`, `te` or
    /// `tel-IN` for the same language, and the setting is one of those three.
    private static func matches(_ rendition: HLSAudioRendition, _ wanted: String) -> Bool {
        if let code = rendition.language?.lowercased(),
           code.hasPrefix(wanted) || wanted.hasPrefix(code) {
            return true
        }
        return rendition.label.lowercased() == wanted
    }

    /// Which track to send first, out of the ones being offered.
    ///
    /// The first in the playlist, in effect — which is what a provider puts
    /// first and what `DEFAULT` almost always marks. The player's
    /// preferred-language setting wins when it has been set, because somebody
    /// who has told this app they want Telugu has already answered this
    /// question once; it is empty unless they filled it in, so the ordinary
    /// case is "the first one".
    ///
    /// Either way it is only a starting point: the cast screen can change it,
    /// which is the whole reason this does not ask.
    static func preferred(among offered: [HLSAudioRendition]) -> HLSAudioRendition? {
        let wanted = preferredLanguage
        if !wanted.isEmpty, let match = offered.first(where: { matches($0, wanted) }) {
            return match
        }
        return offered.first(where: \.isDefault) ?? offered.first
    }

    // MARK: writing

    /// A master declaring exactly one audio rendition, with every URI absolute.
    ///
    /// What survives: the chosen rendition, every variant that references its
    /// group and asks for nothing undecodable, and the subtitle renditions —
    /// a separate pipeline the receiver handles perfectly well, and dropping
    /// them would take captions away to fix an audio problem.
    ///
    /// What goes: the other renditions, the variants belonging to other groups
    /// — a variant naming a group that is no longer declared is a broken
    /// playlist — and `#EXT-X-IMAGE-STREAM-INF`, Roku's trick-play extension,
    /// which no Cast receiver reads and which names a JPEG stream inside a
    /// playlist a strict parser is already struggling with.
    static func singleAudio(_ master: String, base: URL, keeping id: Int) -> String {
        let group = renditions(in: master).first { $0.id == id }?.group ?? ""

        var audioSeen = -1
        var skipNextURI = false
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

            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let wantsGroup = attribute("AUDIO", in: line) ?? ""
                let codecs = attribute("CODECS", in: line) ?? ""
                // A dropped variant takes the line after it with it: that line
                // is its playlist URI, and a bare URL left in a master is a
                // variant with no attributes at all.
                guard wantsGroup == group, !isUndecodable(codecs) else {
                    skipNextURI = true
                    continue
                }
                out.append(line)
                continue
            }

            if line.hasPrefix("#EXT-X-IMAGE-STREAM-INF") { continue }

            // Subtitles are kept but no longer selected for you. They are a
            // third pipeline on a device that is already failing to run two,
            // and these providers ship WebVTT with no `X-TIMESTAMP-MAP` and a
            // single segment claiming 99999 seconds — which is a receiver
            // fetching something strange before the first frame. Declared, so
            // nothing is taken away; not `DEFAULT`, so nothing is fetched
            // unless something asks.
            if line.hasPrefix("#EXT-X-MEDIA:"), attribute("TYPE", in: line) == "SUBTITLES" {
                let quietened = line
                    .replacingOccurrences(of: "DEFAULT=YES", with: "DEFAULT=NO")
                    .replacingOccurrences(of: "AUTOSELECT=YES", with: "AUTOSELECT=NO")
                out.append(absolutised(quietened, base: base))
                continue
            }

            if line.hasPrefix("#") {
                out.append(absolutised(line, base: base))
                continue
            }

            if skipNextURI {
                skipNextURI = false
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
