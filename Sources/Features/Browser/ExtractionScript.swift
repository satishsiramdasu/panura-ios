import Foundation

/// The generic in-page video sniffer, injected into every frame at document end.
/// This is the iOS counterpart to the Android generic extractor: it scans
/// JWPlayer, <video> tags, and inline scripts for m3u8/mp4 URLs and posts each
/// hit back to native over the `panura` message handler.
///
/// Site-specific extractors are intentionally omitted (parity with the Android
/// decision to rely on the generic sniffer).
enum ExtractionScript {
    static let source = #"""
    (function () {
      var seen = {};
      function report(url, title) {
        if (!url || seen[url]) return;
        seen[url] = true;
        try {
          window.webkit.messageHandlers.panura.postMessage({
            url: url, title: title || document.title || ''
          });
        } catch (e) {}
      }

      function scan() {
        // 1) JWPlayer
        try {
          if (window.jwplayer) {
            var pl = jwplayer().getPlaylist();
            if (pl && pl[0] && pl[0].sources) {
              pl[0].sources.forEach(function (s) { report(s.file); });
            }
          }
        } catch (e) {}

        // 2) <video>/<source> elements
        document.querySelectorAll('video, source').forEach(function (el) {
          if (el.src) report(el.src);
        });

        // 3) Inline scripts referencing m3u8/mp4/mpd
        var re = /["'](https?:[^"']+\.(?:m3u8|mp4|mpd)[^"']*)["']/gi;
        document.querySelectorAll('script').forEach(function (s) {
          var t = s.textContent || '', m;
          while ((m = re.exec(t)) !== null) report(m[1]);
        });
      }

      scan();
      // Re-scan for players that load asynchronously.
      var n = 0, iv = setInterval(function () {
        scan();
        if (++n > 20) clearInterval(iv);
      }, 1000);
    })();
    """#
}
