import Foundation

/// What a site calls itself, from its own front page.
///
/// A bookmark is of a site, and the page you were on when you made it is
/// usually not the site: bookmarking from an episode page named the bookmark
/// after the episode, which is wrong the moment you go back to it for anything
/// else. The front page is the one page whose title is about the whole site.
enum SiteTitle {
    /// Cheap and short-lived. A site is bookmarked once, so this only ever
    /// saves the second bookmark of the same host in one session.
    private static var cache: [String: String] = [:]

    /// The root URL of whatever site a page belongs to.
    ///
    /// `www.` is dropped to match how the rest of the app keys hosts, and the
    /// page's own scheme is kept rather than forcing https — a site served over
    /// http is rare now, but rewriting its address into one that does not answer
    /// would make the bookmark dead rather than insecure.
    static func root(of url: URL) -> URL? {
        guard let host = url.host else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return URL(string: "\(url.scheme ?? "https")://\(bare)/")
    }

    /// Fetches the front page and reads its `<title>`.
    ///
    /// Returns nil rather than a guess when anything goes wrong — the caller
    /// already has the host to fall back on, and a host is a worse title than a
    /// real one but a better one than an error.
    static func fetch(root: URL) async -> String? {
        let key = root.absoluteString
        if let hit = cache[key] { return hit }

        var request = URLRequest(url: root)
        // Ten seconds, and the whole document. A Range header would fetch only
        // the head, where every title that has ever been written lives, but a
        // server that refuses ranges answers 416 with no body at all - and
        // losing the title on those sites costs more than the bytes saved on
        // the rest. This runs once per site, behind a bookmark already saved.
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
                + " (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1),
              let title = parse(html)
        else { return nil }

        cache[key] = title
        return title
    }

    /// The document's title, tidied.
    ///
    /// Sites pad the tag with the page name and a separator — "Home - Example",
    /// "Example | Watch free" — and the front page's own name is the part that
    /// survives. Only split when what is left is still worth reading: a title
    /// that is one long phrase with a dash in it must not be cut in half.
    static func parse(_ html: String) -> String? {
        guard let range = html.range(
            of: "<title[^>]*>(.*?)</title>",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }

        var text = String(html[range])
        text = text.replacingOccurrences(
            of: "^<title[^>]*>|</title>$",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = decode(text)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for separator in [" - ", " | ", " – ", " — ", " :: "] {
            guard let head = text.components(separatedBy: separator).first,
                  head.count >= 3, head.count < text.count
            else { continue }
            text = head.trimmingCharacters(in: .whitespaces)
            break
        }

        guard !text.isEmpty else { return nil }
        return text.count > 60 ? String(text.prefix(60)).trimmingCharacters(in: .whitespaces) : text
    }

    /// The handful of entities that actually turn up in a title.
    private static func decode(_ s: String) -> String {
        var out = s
        for (entity, char) in [
            ("&amp;", "&"), ("&#38;", "&"),
            ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#34;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&#x27;", "'"),
            ("&nbsp;", " "), ("&#160;", " "),
            ("&ndash;", "–"), ("&mdash;", "—"),
        ] {
            out = out.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        return out
    }
}
