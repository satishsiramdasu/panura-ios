import Foundation

/// Reports the page's own icon, for the leading cell of the address pill.
///
/// The app's mark used to sit there. On Home that is right — the pill is the
/// app's. In the browser it is wrong twice over: the cell every browser uses to
/// say *what this page is* was saying what the app is, and the one piece of
/// identity the user actually needs while browsing was nowhere on screen.
///
/// **Resolved from the page itself, never from a favicon service.** The usual
/// shortcut is a third-party endpoint that takes a hostname and returns an
/// icon, which would hand every site the user visits to somebody else — and the
/// privacy policy says browsing history never leaves the device. The page is
/// already open, so reading its own `<link rel="icon">` costs no request the
/// browser was not going to make anyway, and tells nobody anything.
///
/// Main frame only, at document end: the head has to have been parsed, and an
/// advert iframe's icon is not this page's.
enum FaviconScript {
    static let source = #"""
    (function () {
      if (window.__panuraFavicon) return;
      window.__panuraFavicon = true;

      function best() {
        try {
          var links = document.querySelectorAll('link[rel]');
          var found = null, bestSize = -1;
          for (var i = 0; i < links.length; i++) {
            var rel = (links[i].getAttribute('rel') || '').toLowerCase();
            if (rel.indexOf('icon') === -1) continue;
            var href = links[i].getAttribute('href');
            if (!href) continue;
            // Prefer the largest declared size, which is usually the only one
            // that is not a 16px bitmap from 2004. `sizes="any"` on an SVG
            // wins outright - it scales.
            var sizes = (links[i].getAttribute('sizes') || '').toLowerCase();
            var size = sizes === 'any' ? 9999 : parseInt(sizes, 10);
            if (isNaN(size)) size = rel.indexOf('apple-touch') !== -1 ? 180 : 32;
            if (size > bestSize) { bestSize = size; found = links[i].href; }
          }
          // Every site has had one of these since before any of this was
          // standardised, so it is the fallback rather than a guess.
          if (!found) found = location.origin + '/favicon.ico';
          return found;
        } catch (e) { return null; }
      }

      function send() {
        try {
          var url = best();
          if (!url) return;
          window.webkit.messageHandlers.panura.postMessage({
            kind: 'favicon', url: url, page: location.href
          });
        } catch (e) {}
      }

      send();
      // Single-page apps swap the icon with the route, and some sites write
      // theirs in from script after load. One late re-read catches both without
      // watching the head for the life of the page.
      setTimeout(send, 1500);
    })();
    """#
}
