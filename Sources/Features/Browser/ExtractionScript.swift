import Foundation

/// Generic in-page video sniffer, injected into every frame at document start.
/// iOS counterpart to the Android generic extractor.
///
/// Two detection layers:
///  1. DOM/JWPlayer/inline-script scanning (direct `.m3u8`/`.mp4` references).
///  2. `fetch` / `XMLHttpRequest` hooks — required for Media Source Extensions
///     sites, where `<video>.src` is only a `blob:` handle and the real manifest
///     is fetched by script. This is our stand-in for Android's
///     `shouldInterceptRequest`, which iOS doesn't provide.
///
/// `blob:` and `data:` URLs are never reported: they're in-page handles that no
/// external player can resolve.
enum ExtractionScript {
    static let source = #"""
    (function () {
      var seen = {};

      function absolute(u) {
        try { return new URL(u, location.href).href; } catch (e) { return u; }
      }

      function isPlayable(u) {
        if (!u || typeof u !== 'string') return false;
        var l = u.toLowerCase();
        // blob:/data: only exist inside this page — useless to an external player.
        if (l.indexOf('blob:') === 0 || l.indexOf('data:') === 0) return false;
        if (l.indexOf('.m3u8') !== -1) return true;
        if (l.indexOf('.mpd') !== -1) return true;
        // Whole-file mp4 only; skip fMP4/HLS segments which are just noise.
        if (l.indexOf('.m4s') !== -1 || l.indexOf('.ts?') !== -1) return false;
        return /\.mp4($|\?|#)/.test(l);
      }

      function report(url, title) {
        if (!isPlayable(url)) return;
        var abs = absolute(url);
        if (seen[abs]) return;
        seen[abs] = true;
        try {
          window.webkit.messageHandlers.panura.postMessage({
            url: abs,
            title: title || document.title || '',
            referer: location.href,
            origin: location.origin,
            ua: navigator.userAgent,
            cookie: document.cookie || ''
          });
        } catch (e) {}
      }

      // ── Layer 2: network hooks (MSE / blob sites) ──────────────────────────
      try {
        var _fetch = window.fetch;
        if (_fetch) {
          window.fetch = function (input) {
            try {
              var u = (typeof input === 'string') ? input : (input && input.url);
              report(u);
            } catch (e) {}
            return _fetch.apply(this, arguments);
          };
        }
      } catch (e) {}

      try {
        var _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { report(url); } catch (e) {}
          return _open.apply(this, arguments);
        };
      } catch (e) {}

      // ── Layer 1: DOM / player / inline-script scan ─────────────────────────
      function scan() {
        try {
          if (window.jwplayer) {
            var pl = jwplayer().getPlaylist();
            if (pl && pl[0] && pl[0].sources) {
              pl[0].sources.forEach(function (s) { report(s.file); });
            }
          }
        } catch (e) {}

        document.querySelectorAll('video, source').forEach(function (el) {
          // currentSrc resolves what's actually loaded; both are blob-filtered.
          report(el.currentSrc);
          report(el.src);
        });

        var re = /["'](https?:[^"']+\.(?:m3u8|mp4|mpd)[^"']*)["']/gi;
        document.querySelectorAll('script').forEach(function (s) {
          var t = s.textContent || '', m;
          while ((m = re.exec(t)) !== null) report(m[1]);
        });
      }

      scan();
      var n = 0, iv = setInterval(function () {
        scan();
        if (++n > 20) clearInterval(iv);
      }, 1000);
    })();
    """#
}
