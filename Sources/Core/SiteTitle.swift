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

    /// Entity-decodes a title that was stored before this decoder existed.
    ///
    /// Titles written by earlier builds kept whatever the markup said, so a
    /// bookmark made last week can still be carrying `&#8211;` in the middle of
    /// it. Cheap enough to run over the saved lists at launch, and a no-op for
    /// every title that has no `&` in it.
    static func clean(_ title: String) -> String {
        title.contains("&") ? decode(title) : title
    }

    /// Entities, named and numeric.
    ///
    /// A title arrives exactly as it was written into the markup, and what
    /// sites write is `&#8211;` — WordPress turns every dash it is handed into
    /// one. A fixed list of names left those showing as their own source code
    /// in the middle of a bookmark, so numbers are decoded as well, which
    /// covers every entity a page can spell that way rather than the dozen
    /// somebody thought to write down.
    private static func decode(_ s: String) -> String {
        var out = s
        for (entity, char) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&ndash;", "–"), ("&mdash;", "—"),
            ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&hellip;", "…"), ("&bull;", "•"), ("&middot;", "·"),
            ("&laquo;", "«"), ("&raquo;", "»"),
            ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™"),
        ] {
            out = out.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        return numeric(out)
    }

    /// `&#8211;` and `&#x2014;`.
    ///
    /// Anything that is not a number, or is too long to be one, is left exactly
    /// as it was: a title containing a stray `&#` is odd, but it is what the
    /// site said and mangling it further helps nobody. The named pass runs
    /// first, so a decoded `&amp;` cannot begin a second round here.
    private static func numeric(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var out = ""
        var rest = Substring(s)
        while let marker = rest.range(of: "&#") {
            out += rest[..<marker.lowerBound]
            let after = rest[marker.upperBound...]
            guard let end = after.firstIndex(of: ";"),
                  after.distance(from: after.startIndex, to: end) <= 7
            else {
                out += "&#"
                rest = after
                continue
            }
            let body = after[..<end]
            let hex = body.first == "x" || body.first == "X"
            let digits = hex ? body.dropFirst() : Substring(body)
            if let value = UInt32(digits, radix: hex ? 16 : 10),
               let scalar = Unicode.Scalar(value) {
                out.append(Character(scalar))
            } else {
                out += "&#\(body);"
            }
            rest = after[after.index(after: end)...]
        }
        return out + rest
    }
}
