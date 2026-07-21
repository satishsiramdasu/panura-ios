import WebKit

/// WKWebView ad/tracker blocker — the iOS port of Android's `AdBlocker`.
///
/// iOS has no `shouldInterceptRequest`, so network blocking is done with a
/// `WKContentRuleList` (Safari's engine) built from the same host + keyword
/// lists. Cosmetic hiding uses the rule engine's native `css-display-none`
/// action. The JS pop-neutralization layer lives in `AdBlockScript`.
enum ContentBlocker {

    static let baseIdentifier = "panura-base"

    /// Compile the static base blocklist (+ optional fetched `extraHosts` such as
    /// oisd domains) into its own rule list.
    static func compile(
        identifier: String = baseIdentifier,
        extraHosts: [String] = []
    ) async -> WKContentRuleList? {
        guard let json = rulesJSON(extraHosts: extraHosts) else { return nil }
        return await compileJSON(identifier: identifier, json: json)
    }

    /// Compile arbitrary content-blocker JSON (e.g. converted EasyList output).
    @MainActor
    static func compileJSON(identifier: String, json: String) async -> WKContentRuleList? {
        let store = WKContentRuleListStore.default()
        return await withCheckedContinuation { cont in
            store?.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                if let error { print("adblock compile failed [\(identifier)]: \(error)") }
                cont.resume(returning: list)
            }
        }
    }

    /// Return an already-compiled list from disk without rebuilding, if present.
    @MainActor
    static func cached(identifier: String = baseIdentifier) async -> WKContentRuleList? {
        await withCheckedContinuation { cont in
            WKContentRuleListStore.default()?
                .lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                    cont.resume(returning: list)
                }
        }
    }

    /// Build the content-rule-list JSON: one block rule per host, per keyword,
    /// plus a single css-display-none rule for cosmetic hiding.
    private static func rulesJSON(extraHosts: [String]) -> String? {
        var rules: [[String: Any]] = []

        // Dedupe base + fetched hosts.
        var seen = Set<String>()
        for host in blockedHosts + extraHosts where seen.insert(host).inserted {
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": ["url-filter": "^https?://([^/]*\\.)?\(escaped)"],
                "action": ["type": "block"],
            ])
        }

        for keyword in blockedKeywords {
            rules.append([
                "trigger": ["url-filter": escapeRegex(keyword)],
                "action": ["type": "block"],
            ])
        }

        // Cosmetic: hide ad containers that slip past network blocking.
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": cosmeticSelector],
        ])

        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func escapeRegex(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ".?+*()[]{}^$|\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// CSS selector group hidden via `css-display-none` (ported from Android).
    private static let cosmeticSelector =
        #"[id^="adngin-"],[id^="google_ads_"],[id^="div-gpt-ad"],ins.adsbygoogle,[class*="adsbygoogle"],"# +
        #"[id*="ad-container"],[class*="ad-container"],[id*="ad_container"],[class*="ad_container"],"# +
        #"[id*="banner-ad"],[class*="banner-ad"],[id*="ad-banner"],[class*="ad-banner"],"# +
        #"[id*="sticky-ad"],[class*="sticky-ad"],[id*="ad-sticky"],[class*="ad-sticky"],"# +
        #"[id*="video-ad"],[class*="video-ad"],[id*="ad-overlay"],[class*="ad-overlay"],"# +
        #"[id*="exoclick"],[class*="exoclick"],[id*="popunder"],[class*="popunder"],"# +
        #"[id*="pop-ad"],[class*="pop-ad"],[class*="overlay-ad"],[id*="overlay-ad"],"# +
        #"[data-ad],[data-ad-slot],[data-ad-unit],.adsbygoogle,#carbonads,.carbon-ads"#

    // Ported from Android AdBlocker.BLOCKED_HOSTS_BASE (base domains).
    private static let blockedHosts: [String] = [
        // Programmatic ad networks
        "doubleclick.net", "googlesyndication.com", "googletagmanager.com",
        "googletagservices.com", "googleadservices.com", "adservice.google.com",
        "adnxs.com", "amazon-adsystem.com", "adsrvr.org", "outbrain.com",
        "taboola.com", "criteo.com", "rubiconproject.com", "pubmatic.com",
        "openx.net", "openx.com", "media.net", "indexexchange.com",
        "sharethrough.com", "spotxchange.com", "spotx.tv", "smartadserver.com",
        "smaato.net", "sovrn.com", "lijit.com", "contextweb.com",
        "casalemedia.com", "appnexus.com", "advertising.com", "oath.com",
        "2mdn.net", "moatads.com", "doubleverify.com", "adsafeprotected.com",
        "adform.net", "adform.com", "lkqd.net", "springserve.com",
        "unrulymedia.com", "rhythmone.com", "1rx.io", "yieldlab.net",
        "improvedigital.com", "teads.tv", "teads.com", "inmobi.com", "turn.com",
        "freewheel.tv", "freewheel.net", "demdex.net", "omtrdc.net",
        "bluekai.com", "crwdcntrl.net", "conversantmedia.com", "rlcdn.com",
        "adition.com", "sizmek.com", "flashtalking.com", "adtng.com",
        // Pop / redirect ads (streaming sites)
        "acscdn.com", "acadscdn.com", "displayvertising.com", "newpopads.net",
        "popads.net", "popcash.net", "popunder.net", "propellerads.com",
        "exoclick.com", "juicyads.com", "trafficjunky.net", "adsterra.com",
        "hilltopads.net", "hilltopads.com", "monetag.com", "adcash.com",
        "clickaine.com", "richpush.co", "pushprofit.com", "a-ads.com",
        "revcontent.com", "traffic-media.co", "plugrush.com", "adspyglass.com",
        "cpmstar.com", "adcolony.com", "admaven.com", "clickadu.com",
        "adtelligent.com", "bidvertiser.com", "mgid.com", "onetag.com",
        "onetag-sys.com", "oxoad.com", "trafficfactory.biz", "traffichunt.com",
        "zeroredirect1.com", "adnetwork.net", "liveadexchanger.com",
        "adxpansion.com", "cpx.to", "popads.com", "etargetnet.com",
        "tsyndicate.com", "adskeeper.co.uk", "adskeeper.com", "popad.co",
        "pops.best", "trafficstars.com", "justpremium.com", "primis.tech",
        "popunders.net", "datamoshi.com", "liveyui.com", "oclaserver.com",
        // Push notification ads
        "push.pub", "pushpush.net", "onclicka.com", "onclickads.net",
        "megapu.sh", "subscribers.com", "izooto.com", "notix.io",
        "pushground.com", "adpushup.com", "pushads.net", "evadav.com",
        "push.house", "pushflew.com", "gravitypush.com", "sendpush.net",
        "web-push.io",
        // Crypto miners
        "coinhive.com", "coin-hive.com", "minero.cc", "webminepool.com",
        "cryptoloot.pro", "authedmine.com", "monerominer.rocks", "jsecoin.com",
        "coinblind.com", "coinzilla.io",
        // Link shorteners / ad redirectors
        "adf.ly", "sh.st", "ouo.io", "bc.vc", "linkbucks.com", "shorte.st",
        "adfoc.us", "lnkfly.com", "go2link.cc", "skiplink.co", "sub2unlock.com",
        "sub4unlock.com", "sub2get.com", "shrinkearn.com", "gplinks.co",
        "shrinkme.io", "shrinkurl.us", "exe.io", "fc.lc", "oke.io",
        "zshort.gq", "cutpaid.com",
        // Analytics / trackers
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "newrelic.com", "hotjar.com", "mouseflow.com", "logrocket.com",
        "fullstory.com", "mixpanel.com", "segment.io", "segment.com",
        "heapanalytics.com", "kissmetrics.com", "intercom.io", "intercom.com",
        "marketo.com", "pardot.com", "comscore.com", "imrworldwide.com",
        "nielsen.com", "brandmetrics.com", "tremorhub.com", "iasds01.com",
        "integral-ad.com", "adscore.com", "ad-score.com", "sentry.io",
        "bugsnag.com", "nr-data.net",
    ]

    // Ported from Android AdBlocker.BLOCKED_URL_KEYWORDS.
    private static let blockedKeywords: [String] = [
        "/popunder", "/pop-under", "/clickunder", "/pops/", "/popads",
        "adserver", "ad_server", "/bannerads/", "/banner_ads/", "tracking.php",
        "click.php?aid=", "click.php?bid=", "/ads/show", "/serve/ads",
        "adsense/show",
    ]
}
