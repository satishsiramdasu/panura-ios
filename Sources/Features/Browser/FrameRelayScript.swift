import Foundation

/// Routes `#referer=` iframes through the local relay.
///
/// Android handles these in `shouldInterceptRequest`: it refetches the frame by
/// hand with the custom Referer and returns the response. WKWebView has no such
/// hook and will not let a page set a header on a frame's own request, so the
/// rewrite happens in the page instead — the `src` is pointed at StreamProxy's
/// `/f` route, which does the gated fetch natively.
///
/// Scope is deliberately narrow: **only** iframes whose `src` carries
/// `#referer=` are touched. That fragment is an explicit instruction from the
/// embed, so a page that doesn't use the convention is never relayed and cannot
/// be broken by this.
///
/// The tradeoff on a relayed frame is its origin: the document comes from
/// 127.0.0.1, so CDN cookies and any same-origin check inside the frame see the
/// relay rather than the real host. `<base href>` (added by the relay) keeps
/// relative assets resolving to the real host. Streams found inside the frame
/// are re-attributed natively, so detection is unaffected.
enum FrameRelayScript {
    static func source(relayBase: String) -> String {
        #"""
        (function () {
          if (window.__panuraFrameRelay) return;
          window.__panuraFrameRelay = true;

          var BASE = '__PANURA_RELAY_BASE__';
          var MARK = '#referer=';

          // base64url, no padding — a raw URL in a query string mangles on `/`,
          // `=` and `+`. unescape(encodeURIComponent(…)) keeps non-ASCII safe.
          function enc(s) {
            try {
              return btoa(unescape(encodeURIComponent(s)))
                .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
            } catch (e) { return ''; }
          }

          function relayURL(raw) {
            var i = raw.indexOf(MARK);
            if (i < 0) return null;
            var target = raw.slice(0, i);
            var referer = decodeURIComponent(raw.slice(i + MARK.length));
            if (referer.indexOf('http') !== 0) return null;
            try { target = new URL(target, location.href).href; } catch (e) {}
            var u = enc(target), r = enc(referer);
            if (!u) return null;
            return BASE + '/f?u=' + u + '&r=' + r;
          }

          function rewrite(frame) {
            var raw = frame.getAttribute('src');
            if (!raw || raw.indexOf(MARK) < 0) return;
            var relayed = relayURL(raw);
            if (!relayed) return;
            // Mark it so the observer doesn't chase its own write.
            frame.setAttribute('data-panura-relayed', raw);
            frame.setAttribute('src', relayed);
          }

          function scan(root) {
            var frames = (root || document).querySelectorAll
              ? (root || document).querySelectorAll('iframe[src*="' + MARK + '"]') : [];
            for (var i = 0; i < frames.length; i++) rewrite(frames[i]);
          }

          // Catch frames written after load — most players insert theirs on play.
          var obs = new MutationObserver(function (muts) {
            for (var i = 0; i < muts.length; i++) {
              var m = muts[i];
              if (m.type === 'attributes' && m.target.tagName === 'IFRAME') {
                rewrite(m.target);
                continue;
              }
              for (var j = 0; j < m.addedNodes.length; j++) {
                var n = m.addedNodes[j];
                if (n.nodeType !== 1) continue;
                if (n.tagName === 'IFRAME') rewrite(n);
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
        .replacingOccurrences(of: "__PANURA_RELAY_BASE__", with: relayBase)
    }
}
