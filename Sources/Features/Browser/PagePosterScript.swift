import Foundation

/// Reports the page's own poster image, so a detected stream can be shown with
/// a picture rather than a glyph.
///
/// There is no frame to take a still from — the video has not been opened, and
/// on a cast it is playing on a television — but the page almost always states
/// its artwork for the benefit of link previews. That is the same picture a
/// person just looked at on the page, which makes it the right one for the
/// found-video sheet, the cast screen and the queue.
///
/// Order is by how specific each source is, not by how common: Open Graph and
/// Twitter cards are written for *this* page, JSON-LD's `thumbnailUrl` is
/// written for this *video*, and a `<video poster>` is the frame the site
/// itself chose. A site logo is never picked deliberately — it only arrives
/// when og:image happens to be one, which is a page saying that is all it has.
///
/// MediaSession artwork, which the sniffer already reports, beats every one of
/// these when it arrives: it describes the item playing rather than the page
/// around it. This only fills the gap, which is most sites.
enum PagePosterScript {
    static let source = #"""
    (function(){
      var last = '';
      function abs(u){
        try { return new URL(u, location.href).href; } catch (e) { return ''; }
      }
      function fromMeta(){
        var keys = [
          'meta[property="og:image:secure_url"]','meta[property="og:image"]',
          'meta[name="og:image"]','meta[name="twitter:image"]',
          'meta[name="twitter:image:src"]','meta[property="twitter:image"]',
          'link[rel="image_src"]'
        ];
        for (var i = 0; i < keys.length; i++) {
          var el = document.querySelector(keys[i]);
          if (!el) continue;
          var v = el.getAttribute('content') || el.getAttribute('href') || '';
          if (v) return abs(v);
        }
        return '';
      }
      function fromJSONLD(){
        try {
          var nodes = document.querySelectorAll('script[type="application/ld+json"]');
          for (var i = 0; i < nodes.length && i < 8; i++) {
            var data;
            try { data = JSON.parse(nodes[i].textContent || 'null'); } catch (e) { continue; }
            var stack = [data];
            while (stack.length) {
              var n = stack.pop();
              if (!n || typeof n !== 'object') continue;
              if (Array.isArray(n)) { for (var j = 0; j < n.length; j++) stack.push(n[j]); continue; }
              var t = n.thumbnailUrl || n.thumbnail || n.image;
              if (typeof t === 'string' && t) return abs(t);
              if (Array.isArray(t) && typeof t[0] === 'string') return abs(t[0]);
              if (t && typeof t === 'object' && typeof t.url === 'string') return abs(t.url);
              for (var k in n) { if (n[k] && typeof n[k] === 'object') stack.push(n[k]); }
            }
          }
        } catch (e) {}
        return '';
      }
      function fromVideo(){
        try {
          var v = document.querySelector('video[poster]');
          if (v) { var p = v.getAttribute('poster'); if (p) return abs(p); }
        } catch (e) {}
        return '';
      }
      function report(){
        try {
          var url = fromMeta() || fromJSONLD() || fromVideo();
          // Data URIs are usually a placeholder pixel, and a poster worth
          // showing is never one.
          if (!url || url.indexOf('data:') === 0 || url === last) return;
          last = url;
          window.webkit.messageHandlers.panura.postMessage({ kind: 'poster', url: url });
        } catch (e) {}
      }
      report();
      setTimeout(report, 1200);
      setTimeout(report, 3000);
      // A single-page app changes the page without reloading it, and the poster
      // changes with it.
      window.addEventListener('popstate', function(){ last = ''; setTimeout(report, 800); });
      window.addEventListener('hashchange', function(){ last = ''; setTimeout(report, 800); });
    })();
    """#
}
