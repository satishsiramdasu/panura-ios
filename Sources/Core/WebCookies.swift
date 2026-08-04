import Foundation
import WebKit

/// Reads the web view's real cookie jar.
///
/// `document.cookie` — what the in-page sniffer can see — is not the whole story
/// and for gated CDNs it is usually the wrong half. It cannot see **HttpOnly**
/// cookies at all, and it only ever covers the frame's own origin, never the CDN
/// the stream actually lives on. WebKit's store has both.
///
/// This is the difference behind "plays on the phone, fails on the TV": the phone
/// fetches the stream through WebKit/URLSession, which attaches the HttpOnly
/// session cookie from this store automatically, so nothing looks wrong locally.
/// Hand a TV the same URL with only the JS-visible cookies and the CDN answers
/// `HTTP 200` with a body reading "security error" — a refusal that no status
/// check catches. Android never hit this because it reads
/// `CookieManager.getCookie(url)`, the native jar, which includes HttpOnly.
enum WebCookies {
    /// `Cookie` header value for `url`, or nil when the jar has nothing for it.
    ///
    /// Cookies for the referer's host are merged in as well, mirroring Android:
    /// the session that authorises the stream is typically set by the embed page,
    /// on a different host from the CDN serving the bytes.
    @MainActor
    static func header(for url: URL, referer: URL?, store: WKHTTPCookieStore) async -> String? {
        let all = await store.allCookies()
        var wanted = all.filter { matches($0, url) }
        if let referer {
            // Same name from two hosts: the stream host's own cookie wins, since
            // that is the one the CDN is checking.
            let names = Set(wanted.map(\.name))
            wanted += all.filter { matches($0, referer) && !names.contains($0.name) }
        }
        guard !wanted.isEmpty else { return nil }
        return wanted.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Whether `cookie` would be sent on a request to `url`, by the usual rules:
    /// domain, path, Secure, and expiry.
    private static func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        // A leading dot means "and every subdomain"; without one the host must
        // match exactly. Checking the suffix either way would send a cookie set
        // for `evil-example.com` to `example.com`.
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            guard host == bare || host.hasSuffix(domain) else { return false }
        } else {
            guard host == domain else { return false }
        }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }

        let path = cookie.path.isEmpty ? "/" : cookie.path
        guard path != "/" else { return true }
        let urlPath = url.path.isEmpty ? "/" : url.path
        return urlPath == path
            || urlPath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }
}

private extension WKHTTPCookieStore {
    /// `getAllCookies` as an await, so callers read as one line.
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
