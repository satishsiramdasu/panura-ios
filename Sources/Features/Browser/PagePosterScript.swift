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
      // WordPress names its featured image in the markup, and a great many
      // video sites are WordPress underneath. `wp-post-image` is the class it
      // puts on that image, and it is the picture the page itself considers to
      // be what the post is about.
      function fromArticle(){
        try {
          var picks = [
            'img.wp-post-image', '.post-thumbnail img', '.entry-content img',
            'article img', '.video-thumb img', '.thumb img'
          ];
          for (var i = 0; i < picks.length; i++) {
            var el = document.querySelector(picks[i]);
            if (!el) continue;
            var src = el.currentSrc || el.getAttribute('src') || '';
            if (src && !tooSmall(el)) return abs(src);
          }
        } catch (e) {}
        return '';
      }
      // The biggest picture on the page, as a last resort. A poster is always
      // one of the largest things a page draws, and a logo or an icon never is.
      function fromLargest(){
        try {
          var imgs = document.images || [], best = null, bestArea = 0;
          for (var i = 0; i < imgs.length && i < 120; i++) {
            var el = imgs[i];
            var w = el.naturalWidth || el.width || 0;
            var h = el.naturalHeight || el.height || 0;
            var area = w * h;
            // Wider than tall, and big enough to be content: a poster, not a
            // sidebar avatar or a sponsor's badge.
            if (w < 240 || h < 120 || area <= bestArea) continue;
            best = el; bestArea = area;
          }
          if (best) {
            var src = best.currentSrc || best.getAttribute('src') || '';
            if (src) return abs(src);
          }
        } catch (e) {}
        return '';
      }
      function tooSmall(el){
        var w = el.naturalWidth || el.width || 0;
        return w > 0 && w < 160;
      }
      function fromVideo(){
        try {
          var v = document.querySelector('video[poster]');
          if (v) { var p = v.getAttribute('poster'); if (p) return abs(p); }
        } catch (e) {}
        return '';
      }
      // Sends the same answer every time it is asked, deliberately.
      //
      // It used to remember what it had sent and stay quiet afterwards, which
      // assumed the app still had it. The app drops the poster whenever it
      // decides the page has changed, and it can decide that after this script
      // has already spoken — so one ill-timed clear lost the poster for the
      // life of the page. Re-stating it costs one small message; the app just
      // assigns the same URL again.
      function report(){
        try {
          var url = fromMeta() || fromJSONLD() || fromVideo()
                    || fromArticle() || fromLargest();
          // Data URIs are usually a placeholder pixel, and a poster worth
          // showing is never one.
          if (!url || url.indexOf('data:') === 0) return;
          window.webkit.messageHandlers.panura.postMessage({ kind: 'poster', url: url });
        } catch (e) {}
      }
      report();
      setTimeout(report, 1200);
      setTimeout(report, 3000);
      // Images decode after the document is done, and `naturalWidth` is 0 until
      // they do — the size-based fallbacks are blind before that.
      setTimeout(report, 6000);
      window.addEventListener('load', function(){ setTimeout(report, 400); });
      // A single-page app changes the page without reloading it, and the poster
      // changes with it.
      window.addEventListener('popstate', function(){ setTimeout(report, 800); });
      window.addEventListener('hashchange', function(){ setTimeout(report, 800); });
      // Then once every five seconds for a minute, and no longer: a page that
      // has not settled inside a minute is not going to, and a detection can
      // arrive long after the sweeps above have finished.
      var beats = 0;
      var timer = setInterval(function(){
        if (++beats > 12) { clearInterval(timer); return; }
        report();
      }, 5000);
    })();
    """#
}
