import Foundation

/// The `#referer=` URL convention, ported from Android's `loadWithReferer` and
/// its `shouldInterceptRequest` branch.
///
/// An embed CDN (or an `.m3u` playlist entry) can name the Referer a URL must be
/// fetched with by hanging it off the fragment:
///
///     https://cdn.example.com/v/abc#referer=https%3A%2F%2Fsite.com
///
/// The fragment is never sent to the server, so it is a safe carrier. We strip
/// it and send the value as the `Referer` header instead — which is what the CDN
/// is actually gating on.
///
/// It outranks every other referer source: it is an explicit instruction, where
/// the captured header and the page URL are both inferences.
enum RefererFragment {
    private static let prefix = "referer="

    /// Splits a URL into the URL to request and the Referer it asked for.
    /// Returns `referer == nil` when there is no `#referer=` fragment, leaving
    /// the URL untouched — including any ordinary fragment it may carry.
    static func split(_ url: URL) -> (url: URL, referer: String?) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.percentEncodedFragment,
              raw.hasPrefix(prefix)
        else { return (url, nil) }

        let encoded = String(raw.dropFirst(prefix.count))
        let referer = encoded.removingPercentEncoding ?? encoded
        guard referer.hasPrefix("http") else { return (url, nil) }

        components.fragment = nil
        return (components.url ?? url, referer)
    }

    /// A request for `url` with the fragment's Referer applied, if it named one.
    static func request(for url: URL) -> URLRequest {
        let (clean, referer) = split(url)
        var request = URLRequest(url: clean)
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        return request
    }
}
