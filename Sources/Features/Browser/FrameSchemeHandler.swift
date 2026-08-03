import Foundation
import WebKit

/// Serves `#referer=` iframes over a custom scheme, so WebKit hands us the
/// request and we can fetch it with the Referer the CDN demands.
///
/// This replaces an earlier attempt that pointed such frames at the local
/// StreamProxy over `http://127.0.0.1`. That never loaded: the embedding page is
/// https, so the frame was mixed content and WebKit blocked it outright — before
/// any request, which is why the frames were blank and the sniffer log stayed
/// empty. `NSAllowsArbitraryLoads` does not help; ATS governs the app's own
/// networking, not the page's mixed-content rule, and unlike Chrome, WebKit does
/// not treat http://127.0.0.1 as a trustworthy origin.
///
/// A custom scheme sidesteps both: it is not http, so mixed-content blocking
/// does not apply, and `WKURLSchemeHandler` is the one place WebKit lets an app
/// answer a page's request itself — Android's `shouldInterceptRequest`, near
/// enough.
final class FrameSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Must not be http/https — WebKit reserves those and will refuse to
    /// register a handler for them.
    static let scheme = "panura-frame"

    private let session = URLSession(configuration: .ephemeral)
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private let lock = NSLock()

    /// Reports into the Diagnostics log. Whether this fires at all is the whole
    /// question when a relayed frame comes up blank: silence means WebKit never
    /// issued the request (blocked in the page — CSP, sandbox, or the rewrite
    /// never happened), while a failure here means the upstream fetch is at fault.
    var onEvent: ((_ url: String, _ verdict: String) -> Void)?

    // MARK: URL shape

    /// `panura-frame://relay/?u=<base64url target>&r=<base64url referer>`
    /// Stateless, so a relayed frame survives a reload with nothing remembered.
    static func relayURL(target: String, referer: String) -> String {
        "\(scheme)://relay/?u=\(base64URLEncode(target))&r=\(base64URLEncode(referer))"
    }

    /// Reverses a relay URL back to what it stands for, so a stream found inside
    /// a relayed frame is attributed to the real page and not to the scheme.
    static func relayTarget(of url: URL) -> (url: URL, referer: String)? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let u = items.first(where: { $0.name == "u" })?.value,
              let target = base64URLDecode(u).flatMap(URL.init(string:))
        else { return nil }
        let referer = items.first(where: { $0.name == "r" })?.value.flatMap(base64URLDecode) ?? ""
        return (target, referer)
    }

    /// base64url, no padding — a raw URL in a query string mangles on `/`, `=`
    /// and `+`, the same trap already documented on StreamProxy's `/p` route.
    static func base64URLEncode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let (target, referer) = Self.relayTarget(of: url),
              let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            onEvent?(urlSchemeTask.request.url?.absoluteString ?? "", "frame: bad relay URL")
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        onEvent?(target.absoluteString, "frame: fetching with referer \(referer.isEmpty ? "(none)" : referer)")

        var request = URLRequest(url: target)
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let ua = urlSchemeTask.request.value(forHTTPHeaderField: "User-Agent") {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }

        let key = ObjectIdentifier(urlSchemeTask)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            // A task WebKit already stopped must never be touched again — doing
            // so traps. `finish` clears the registry under the same lock.
            guard self.isLive(key) else { return }

            if let error {
                self.onEvent?(target.absoluteString, "frame: upstream failed — \(error.localizedDescription)")
                self.finish(key) { urlSchemeTask.didFailWithError(error) }
                return
            }

            let mime = (response as? HTTPURLResponse)?.mimeType ?? response?.mimeType ?? "text/html"
            var body = data ?? Data()

            // Relative URLs in the document would otherwise resolve against the
            // custom scheme. `<base>` points them back at the real host so the
            // frame's own assets still load, straight from the CDN.
            if mime.contains("html"), var html = String(data: body, encoding: .utf8) {
                let baseTag = "<base href=\"\(target.absoluteString)\">"
                if let head = html.range(of: "<head", options: .caseInsensitive),
                   let close = html.range(of: ">", range: head.upperBound..<html.endIndex) {
                    html.insert(contentsOf: baseTag, at: close.upperBound)
                } else {
                    html = baseTag + html
                }
                body = Data(html.utf8)
            }

            let headers = [
                "Content-Type": mime,
                "Content-Length": "\(body.count)",
                // The frame is a different origin from the page that embeds it;
                // without this its scripts cannot be read cross-origin.
                "Access-Control-Allow-Origin": "*",
            ]
            let http = HTTPURLResponse(
                url: url,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!

            self.onEvent?(
                target.absoluteString,
                "frame: served \(http.statusCode), \(mime), \(body.count) bytes"
            )
            self.finish(key) {
                urlSchemeTask.didReceive(http)
                urlSchemeTask.didReceive(body)
                urlSchemeTask.didFinish()
            }
        }

        lock.lock(); tasks[key] = task; lock.unlock()
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        let task = tasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    /// Still WebKit's to talk to? `stop` removes it, and after that every call on
    /// the task is a hard crash.
    private func isLive(_ key: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks[key] != nil
    }

    /// Deregisters, then runs the WebKit callbacks — on the main thread, since
    /// they must not race `stop`.
    private func finish(_ key: ObjectIdentifier, _ body: @escaping () -> Void) {
        lock.lock()
        let live = tasks.removeValue(forKey: key) != nil
        lock.unlock()
        guard live else { return }
        DispatchQueue.main.async(execute: body)
    }
}
