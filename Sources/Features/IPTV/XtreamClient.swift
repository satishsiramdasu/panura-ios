import Foundation

/// Talks to an Xtream Codes panel.
///
/// This is the API nearly every IPTV panel speaks, and — the reason there is
/// one client here rather than two — it is also what **Dispatcharr** exposes:
/// its output modes are M3U, XMLTV, Xtream Codes API and HDHomeRun. A
/// Dispatcharr server is therefore an Xtream server as far as this code is
/// concerned, and signing into one is signing into the other with a different
/// host. Writing a second client would have been writing the same client.
///
/// **Decoded by hand, not by `Codable`.** Panels disagree with each other and
/// with themselves about types: `category_id` comes back as `"5"` from one
/// server and `5` from the next, `exp_date` is a string of seconds, an integer,
/// or null, and a panel with no VOD answers `get_live_streams` with `[]` but
/// answers the account call with an object where a list was documented. A
/// `Codable` model throws on the first of those and takes the whole channel
/// list with it. Reading loosely costs twenty lines and survives the estate.
enum XtreamClient {
    struct Account {
        /// "Active", or whatever the panel says.
        let status: String?
        let expires: Date?
        let maxConnections: Int?
    }

    enum Failure: LocalizedError {
        case badHost
        case unreachable
        case refused
        case notXtream

        var errorDescription: String? {
            switch self {
            case .badHost:
                return "That server address is not valid. It should look like http://example.com:8080"
            case .unreachable:
                return "Could not reach that server."
            case .refused:
                // The single most common outcome, and it is never the address.
                return "The server rejected that username or password."
            case .notXtream:
                return "That address answered, but not like an Xtream or Dispatcharr server."
            }
        }
    }

    /// Everything the channel list needs, in two calls.
    ///
    /// Categories first because the streams only carry a `category_id`, and a
    /// channel list grouped by number instead of by name is a channel list
    /// nobody can navigate.
    static func load(
        host: String,
        username: String,
        password: String
    ) async throws -> (channels: [M3UChannel], account: Account) {
        guard let base = normalised(host) else { throw Failure.badHost }

        let account = try await self.account(base: base, username: username, password: password)

        let categories = try await rows(
            base: base, username: username, password: password,
            action: "get_live_categories"
        )
        var names: [String: String] = [:]
        for row in categories {
            guard let id = string(row["category_id"]) else { continue }
            names[id] = string(row["category_name"]) ?? ""
        }

        let streams = try await rows(
            base: base, username: username, password: password,
            action: "get_live_streams"
        )

        let user = escape(username)
        let pass = escape(password)
        var channels: [M3UChannel] = []
        channels.reserveCapacity(streams.count)

        for row in streams {
            guard let id = string(row["stream_id"]),
                  let name = string(row["name"]),
                  // `.ts` rather than `.m3u8`: every panel serves it, not every
                  // panel serves the other, and VLC opens both.
                  let url = URL(string: "\(base)/live/\(user)/\(pass)/\(id).ts")
            else { continue }
            let group = string(row["category_id"]).flatMap { names[$0] }
            channels.append(
                M3UChannel(
                    name: name,
                    url: url,
                    group: (group?.isEmpty == false) ? group : nil,
                    logo: string(row["stream_icon"]).flatMap(URL.init(string:))
                )
            )
        }

        guard !channels.isEmpty else { throw Failure.notXtream }
        return (channels, account)
    }

    // MARK: calls

    private static func account(
        base: String, username: String, password: String
    ) async throws -> Account {
        let object = try await json(base: base, username: username, password: password, action: nil)
        guard let top = object as? [String: Any],
              let info = top["user_info"] as? [String: Any]
        else { throw Failure.notXtream }

        // Refused only on an explicit negative. Panels set one of these two and
        // not reliably the other, and an unfamiliar status is not a reason to
        // turn away a server that is about to hand over a channel list.
        let status = string(info["status"])
        let dead = ["disabled", "expired", "banned"]
        if integer(info["auth"]) == 0
            || dead.contains(status?.lowercased() ?? "") {
            throw Failure.refused
        }

        return Account(
            status: status,
            expires: integer(info["exp_date"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            maxConnections: integer(info["max_connections"])
        )
    }

    private static func rows(
        base: String, username: String, password: String, action: String
    ) async throws -> [[String: Any]] {
        let object = try await json(base: base, username: username, password: password, action: action)
        // A panel with nothing in a category answers with an empty array; one
        // that is unhappy answers with an object. Neither is a crash.
        return (object as? [[String: Any]]) ?? []
    }

    private static func json(
        base: String, username: String, password: String, action: String?
    ) async throws -> Any {
        var text = "\(base)/player_api.php?username=\(escape(username))&password=\(escape(password))"
        if let action { text += "&action=\(action)" }
        guard let url = URL(string: text) else { throw Failure.badHost }

        var request = URLRequest(url: url)
        // These panels are frequently slow and frequently oversubscribed.
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { throw Failure.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 401 || http.statusCode == 403
                ? Failure.refused : Failure.unreachable
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.notXtream
        }
        return object
    }

    // MARK: loose reading

    /// `"5"`, `5` and `5.0` all mean five.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }

    /// Credentials go in a path segment as well as a query, so they are escaped
    /// for the stricter of the two.
    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// `example.com:8080` and `http://example.com:8080/` both mean the same
    /// server. People paste all of it, some of it, and a trailing slash.
    static func normalised(_ host: String) -> String? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            // Panels are overwhelmingly plain HTTP, and guessing https for one
            // that is not costs a timeout per call.
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return text
    }

    /// The channel list as an M3U, so one cache format serves both kinds of
    /// account — see `IPTVStore`.
    static func m3u(_ channels: [M3UChannel]) -> String {
        var text = "#EXTM3U\n"
        for channel in channels {
            text += "#EXTINF:-1"
            if let logo = channel.logo { text += " tvg-logo=\"\(logo.absoluteString)\"" }
            if let group = channel.group { text += " group-title=\"\(group)\"" }
            text += ",\(channel.name)\n\(channel.url.absoluteString)\n"
        }
        return text
    }
}
