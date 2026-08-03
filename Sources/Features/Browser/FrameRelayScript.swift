import Foundation

/// Handles `#referer=` iframes — the embed convention where a CDN names the
/// Referer its page must be fetched with, hung off the fragment.
///
/// Android intercepts these in `shouldInterceptRequest` and refetches the frame
/// by hand. WKWebView has no equivalent hook and will not let a page set a
/// header on a frame's own request, so two page-side rewrites were tried and
/// both failed the same way: pointing the frame at a local `http://127.0.0.1`
/// relay, then at a custom `panura-frame:` scheme. The host page is https and
/// neither is a trustworthy origin to WebKit, so each was mixed content and
/// blocked before a request ever left the page — the frame simply went blank,
/// with no CSP violation and no error the page could observe.
///
/// So the frame is no longer rewritten at all. It is reported to native, which
/// loads it offscreen as a **main frame** — where a `Referer` header is legal
/// and mixed content does not apply. See `EmbedExtractor`.
///
/// Two things still happen here:
///  • Same-origin fast path. When the demanded Referer is the page's own origin,
///    `referrerpolicy="unsafe-url"` makes WebKit send it, and the frame loads
///    inline with no extraction at all.
///  • Everything is logged to Diagnostics, so a frame that goes nowhere can be
///    told apart from one that was never matched.
enum FrameRelayScript {
    static var source: String {
        #"""
        (function () {
          if (window.__panuraFrameRelay) return;
          window.__panuraFrameRelay = true;

          var MARK = '#referer=';

          function post(payload) {
            try { window.webkit.messageHandlers.panura.postMessage(payload); } catch (e) {}
          }

          function note(url, verdict) {
            post({
              kind: 'debug', url: url || '', verdict: verdict,
              host: location.host, src: 'frame-relay'
            });
          }

          function handle(frame) {
            var raw = frame.getAttribute('src');
            if (!raw || raw.indexOf(MARK) < 0) return;
            if (frame.getAttribute('data-panura-seen')) return;
            frame.setAttribute('data-panura-seen', '1');

            var i = raw.indexOf(MARK);
            var target = raw.slice(0, i);
            var referer = decodeURIComponent(raw.slice(i + MARK.length));
            try { target = new URL(target, location.href).href; } catch (e) {}
            if (referer.indexOf('http') !== 0) {
              note(raw, 'frame: unusable #referer= value');
              return;
            }

            // Fast path: the page can send this Referer itself. `unsafe-url`
            // overrides the default strict-origin-when-cross-origin, which would
            // send only the origin and drop the path. No extraction needed.
            var sameOrigin = false;
            try { sameOrigin = new URL(referer).origin === location.origin; } catch (e) {}
            if (sameOrigin) {
              frame.setAttribute('referrerpolicy', 'unsafe-url');
              frame.setAttribute('src', target);
              note(target, 'frame: same-origin referer, policy=unsafe-url');
              return;
            }

            // Cross-origin: WebKit will send the wrong Referer and the CDN will
            // refuse, so extract it offscreen instead. The visible frame is left
            // exactly as the page wrote it — whatever it does is the site's own
            // behaviour, not something this script caused.
            note(target, 'frame: cross-origin referer, extracting offscreen');
            post({ kind: 'embed', url: target, referer: referer });
          }

          function scan(root) {
            var r = root || document;
            if (!r.querySelectorAll) return;
            var frames = r.querySelectorAll('iframe[src*="' + MARK + '"]');
            for (var i = 0; i < frames.length; i++) handle(frames[i]);
          }

          // Catch frames written after load — most players insert theirs on play.
          var obs = new MutationObserver(function (muts) {
            for (var i = 0; i < muts.length; i++) {
              var m = muts[i];
              if (m.type === 'attributes' && m.target.tagName === 'IFRAME') {
                handle(m.target);
                continue;
              }
              for (var j = 0; j < m.addedNodes.length; j++) {
                var n = m.addedNodes[j];
                if (n.nodeType !== 1) continue;
                if (n.tagName === 'IFRAME') handle(n);
                else scan(n);
              }
            }
          });

          function startObserving() {
            scan(document);
            obs.observe(document.documentElement || document, {
              childList: true, subtree: true, attributes: true, attributeFilter: ['src']
            });
          }

          if (document.documentElement) startObserving();
          else document.addEventListener('DOMContentLoaded', startObserving);
        })();
        """#
    }
}
