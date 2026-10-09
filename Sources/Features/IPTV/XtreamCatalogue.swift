import Foundation

/// A series, as the panel lists it. Episodes arrive later, per series.
struct XtreamSeries: Identifiable, Hashable {
    let id: String
    let name: String
    let cover: URL?
    let group: String?
    let plot: String?
}

/// One season of one series.
struct XtreamSeason: Identifiable, Hashable {
    var id: Int { number }
    let number: Int
    let episodes: [XtreamEpisode]
}

struct XtreamEpisode: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let still: URL?
    let plot: String?
}

/// Films and series from an Xtream panel.
///
/// Separate from `XtreamClient` because it is separate in use: live channels
/// are fetched the moment an account is opened and are what most people come
/// for, while these two are fetched only when somebody asks for them. A panel's
/// film catalogue is routinely larger than its channel list, and pulling it on
/// sign-in would make every launch pay for something most sessions never open.
extension XtreamClient {
    /// Films. Modelled as `M3UChannel` because that is exactly what one is here
    /// — a name, a picture, a category and a URL — and reusing it means the
    /// list that draws channels draws films with no second implementation.
    static func movies(
        host: String, username: String, password: String
    ) async throws -> [M3UChannel] {
        guard let base = normalised(host) else { throw Failure.badHost }
        let names = try await categoryNames(
            base: base, username: username, password: password,
            action: "get_vod_categories"
        )
        let rows = try await rows(
            base: base, username: username, password: password,
            action: "get_vod_streams"
        )

        let user = escape(username)
        let pass = escape(password)
        var films: [M3UChannel] = []
        films.reserveCapacity(rows.count)

        for row in rows {
            guard let id = string(row["stream_id"]), let name = string(row["name"]) else { continue }
            // A film is served under the container it was uploaded in, and the
            // panel is the only thing that knows which. mp4 is the common case
            // and the only sane guess when the field is missing.
            let ext = string(row["container_extension"]) ?? "mp4"
            guard let url = URL(string: "\(base)/movie/\(user)/\(pass)/\(id).\(ext)") else { continue }
            let group = string(row["category_id"]).flatMap { names[$0] }
            films.append(
                M3UChannel(
                    name: name,
                    url: url,
                    group: (group?.isEmpty == false) ? group : nil,
                    logo: string(row["stream_icon"]).flatMap(URL.init(string:))
                )
            )
        }
        return films
    }

    static func series(
        host: String, username: String, password: String
    ) async throws -> [XtreamSeries] {
        guard let base = normalised(host) else { throw Failure.badHost }
        let names = try await categoryNames(
            base: base, username: username, password: password,
            action: "get_series_categories"
        )
        let rows = try await rows(
            base: base, username: username, password: password,
            action: "get_series"
        )

        return rows.compactMap { row in
            guard let id = string(row["series_id"]), let name = string(row["name"]) else { return nil }
            let group = string(row["category_id"]).flatMap { names[$0] }
            return XtreamSeries(
                id: id,
                name: name,
                cover: string(row["cover"]).flatMap(URL.init(string:)),
                group: (group?.isEmpty == false) ? group : nil,
                plot: string(row["plot"])
            )
        }
    }

    /// The seasons and episodes of one series.
    ///
    /// `episodes` comes back as an object keyed by season number — `{"1": [...],
    /// "2": [...]}` — rather than as an array, which is why this is read by hand
    /// like the rest of it.
    static func episodes(
        host: String, username: String, password: String, seriesID: String
    ) async throws -> [XtreamSeason] {
        guard let base = normalised(host) else { throw Failure.badHost }
        let object = try await json(
            base: base, username: username, password: password,
            action: "get_series_info&series_id=\(seriesID)"
        )
        guard let top = object as? [String: Any],
              let bySeason = top["episodes"] as? [String: Any]
        else { return [] }

        let user = escape(username)
        let pass = escape(password)
        var seasons: [XtreamSeason] = []

        for (key, value) in bySeason {
            guard let list = value as? [[String: Any]] else { continue }
            var episodes: [XtreamEpisode] = []
            for row in list {
                guard let id = string(row["id"]) else { continue }
                let ext = string(row["container_extension"]) ?? "mp4"
                guard let url = URL(string: "\(base)/series/\(user)/\(pass)/\(id).\(ext)") else {
                    continue
                }
                let number = integer(row["episode_num"]) ?? 0
                let info = row["info"] as? [String: Any]
                episodes.append(
                    XtreamEpisode(
                        id: id,
                        number: number,
                        // Panels often leave the title empty and expect the
                        // client to say "Episode 3".
                        title: string(row["title"]) ?? "Episode \(number)",
                        url: url,
                        still: (info?["movie_image"]).flatMap(string).flatMap(URL.init(string:)),
                        plot: (info?["plot"]).flatMap(string)
                    )
                )
            }
            guard !episodes.isEmpty else { continue }
            seasons.append(
                XtreamSeason(
                    number: Int(key) ?? 0,
                    episodes: episodes.sorted { $0.number < $1.number }
                )
            )
        }
        return seasons.sorted { $0.number < $1.number }
    }

    private static func categoryNames(
        base: String, username: String, password: String, action: String
    ) async throws -> [String: String] {
        let rows = try await rows(base: base, username: username, password: password, action: action)
        var names: [String: String] = [:]
        for row in rows {
            guard let id = string(row["category_id"]) else { continue }
            names[id] = string(row["category_name"]) ?? ""
        }
        return names
    }
}
