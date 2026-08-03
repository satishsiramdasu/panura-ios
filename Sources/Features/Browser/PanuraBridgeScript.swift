import Foundation

/// Page-visible Panura surface, injected into every frame at document start.
///
/// Two things live here:
///
///  1. `window.PanuraExtractor` — the Android `@JavascriptInterface` object,
///     rebridged to `webkit.messageHandlers.panura`. A page (or a script we
///     inject later) can report a stream the generic sniffer missed, exactly as
///     it would on Android.
///  2. `window._ac` — the build's identity marker. A page can feature-detect
///     Panura with `window._ac === '<token>'`. It is readable by every page it
///     is injected into and can be copied by anyone who reads it once, so it
///     identifies the app; it does not authenticate it.
///
/// Both are defined non-writable and non-configurable so a page script cannot
/// replace `PanuraExtractor` with its own object and harvest what gets reported.
/// `_ac` is non-enumerable too — a `for…in` over `window` won't list it, while
/// the direct comparison still works.
enum PanuraBridgeScript {
    /// Identity token. Must match whatever checks `window._ac` on the page side.
    static let identity = "a7f3c9e2b1d84f650e3a2c7b9d1f4e80"

    static var source: String {
        #"""
        (function () {
          if (window.PanuraExtractor) return;

          function post(payload) {
            try { window.webkit.messageHandlers.panura.postMessage(payload); } catch (e) {}
          }

          // Same gating context the sniffer sends, so a bridge-reported hit is
          // replayable by the native player on identical terms.
          function emit(url, title) {
            if (!url) return;
            var abs;
            try { abs = new URL(url, location.href).href; } catch (e) { abs = url; }
            var site = window.__panuraRule || null;
            var mode = (site && site.referer) || 'page';
            post({
              kind: 'video',
              url: abs,
              title: title || document.title || '',
              referer: mode === 'none' ? '' : (mode === 'origin' ? location.origin + '/' : location.href),
              origin: location.origin,
              ua: navigator.userAgent,
              cookie: document.cookie || '',
              type: (site && site.type) || '',
              siteId: (site && site.id) || '',
              headers: (site && site.headers) || null
            });
          }

          var api = {
            onVideoFound: function (url, title) { emit(url, title); },
            // Android uses this to select an already-detected embed; iOS has no
            // embed list, so a user-initiated play is treated as a plain hit.
            onUserPlay: function (url, title) { emit(url, title); },
            onMediaSession: function (title, artist, art) {
              post({ kind: 'meta', title: title || '', artist: artist || '', art: art || '' });
            }
          };

          try {
            Object.defineProperty(window, 'PanuraExtractor', {
              value: Object.freeze(api), writable: false, configurable: false, enumerable: false
            });
            Object.defineProperty(window, '_ac', {
              value: '__PANURA_IDENTITY__', writable: false, configurable: false, enumerable: false
            });
          } catch (e) {
            // Sealed/frozen window (rare, some hardened pages) — best effort.
            window.PanuraExtractor = api;
            window._ac = '__PANURA_IDENTITY__';
          }
        })();
        """#
        .replacingOccurrences(of: "__PANURA_IDENTITY__", with: identity)
    }
}
