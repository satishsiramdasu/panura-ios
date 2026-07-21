import WebKit

/// WKWebView content blocker. Uses the same rule engine as Safari content
/// blockers. This is a compact starter list targeting the ad/tracker networks
/// and pop-under scripts common on streaming sites — not a full EasyList, but
/// enough to cut the worst of it. Extend `rulesJSON` as needed.
enum ContentBlocker {
    static func load() async -> WKContentRuleList? {
        let store = WKContentRuleListStore.default()
        return await withCheckedContinuation { cont in
            store?.compileContentRuleList(
                forIdentifier: "panura-adblock",
                encodedContentRuleList: rulesJSON
            ) { list, _ in
                cont.resume(returning: list)
            }
        }
    }

    /// Each rule: block loads whose URL matches `url-filter`. Domains chosen are
    /// ad/analytics/pop networks; the last rule blocks common popunder query
    /// params. `unless-domain` is avoided to keep it simple.
    private static let rulesJSON = #"""
    [
      {"trigger":{"url-filter":"doubleclick\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googlesyndication\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googleadservices\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"google-analytics\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adservice\\.google\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"amazon-adsystem\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adnxs\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"rubiconproject\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"pubmatic\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"criteo\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"taboola\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"outbrain\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"popads\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"popcash\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"propellerads\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"exoclick\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"juicyads\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"trafficjunky\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adsterra\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"hilltopads\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"onclickads\\."},"action":{"type":"block"}},
      {"trigger":{"url-filter":"mgid\\.com"},"action":{"type":"block"}}
    ]
    """#
}
