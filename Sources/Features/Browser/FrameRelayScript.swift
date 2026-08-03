import Foundation

/// Routes `#referer=` iframes through `FrameSchemeHandler`.
///
/// Android handles these in `shouldInterceptRequest`: it refetches the frame by
/// hand with the custom Referer and returns the response. WKWebView has no such
/// hook and will not let a page set a header on a frame's own request, so the
/// rewrite happens in the page instead — the `src` is pointed at the custom
/// `panura-frame:` scheme, which does the gated fetch natively.
///
/// The scheme is not incidental. An earlier attempt pointed these frames at the
/// local StreamProxy over `http://127.0.0.1`, and they rendered blank: the
/// embedding page is https, so the frame was mixed content and WebKit refused it
/// before issuing any request. A custom scheme is exempt from that rule.
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
    static var source: String {
        #"""
        (function () {
          if (window.__panuraFrameRelay) return;
          window.__panuraFrameRelay = true;

          var SCHEME = '__PANURA_SCHEME__';
          var MARK = '#referer=';

          // Every decision is logged, so a frame that stays blank can be told
          // apart from one that was never matched. Shows in Diagnostics.
          function note(url, verdict) {
            try {
              window.webkit.messageHandlers.panura.postMessage({
                kind: 'debug', url: url || '', verdict: verdict,
                host: location.host, src: 'frame-relay'
              });
            } catch (e) {}
          }

          // If CSP is what kills the frame, the engine says so here — and this is
          // the only way to see a header-delivered policy from inside the page.
          // `blockedURI` + `violatedDirective` name the cause outright.
          try {
            document.addEventListener('securitypolicyviolation', function (e) {
              if (String(e.blockedURI || '').indexOf(SCHEME) < 0 &&
                  String(e.violatedDirective || '').indexOf('frame') < 0) return;
              note(e.blockedURI || '', 'CSP blocked: ' + e.violatedDirective +
                   ' (policy: ' + (e.originalPolicy || '').slice(0, 200) + ')');
            });
          } catch (e) {}

          // Second probe: can this page reach the scheme AT ALL, outside a frame?
          // Reachable here but dead in an iframe means the scheme is fine and the
          // frame is being blocked; dead both ways means the scheme never
          // resolves in this context and the relay approach cannot work as built.
          function probeScheme(url) {
            try {
              fetch(url, { method: 'GET' })
                .then(function (r) { note(url, 'scheme probe: reachable, status ' + r.status); })
                .catch(function (err) { note(url, 'scheme probe: failed — ' + err); });
            } catch (e) { note(url, 'scheme probe: threw — ' + e); }
          }

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
            return SCHEME + '://relay/?u=' + u + '&r=' + r;
          }

          function rewrite(frame) {
            var raw = frame.getAttribute('src');
            if (!raw || raw.indexOf(MARK) < 0) return;

            var i = raw.indexOf(MARK);
            var target = raw.slice(0, i);
            var referer = decodeURIComponent(raw.slice(i + MARK.length));
            try { target = new URL(target, location.href).href; } catch (e) {}

            // Fast path: when the demanded Referer is this page's own origin,
            // WebKit can send it itself. `unsafe-url` overrides the default
            // strict-origin-when-cross-origin, which would send only the origin
            // and drop the path. No relay, no custom scheme, no CSP question.
            var sameOrigin = false;
            try { sameOrigin = new URL(referer).origin === location.origin; } catch (e) {}
            if (sameOrigin) {
              frame.setAttribute('referrerpolicy', 'unsafe-url');
              frame.setAttribute('src', target);
              note(target, 'frame: same-origin referer, policy=unsafe-url');
              return;
            }

            var relayed = relayURL(raw);
            if (!relayed) { note(raw, 'frame: unusable #referer= value'); return; }
            // Mark it so the observer doesn't chase its own write.
            frame.setAttribute('data-panura-relayed', raw);
            frame.setAttribute('src', relayed);
            note(target, 'frame: rewritten to ' + SCHEME + ':');
            probeScheme(relayed);

            // Did the frame actually load? A blocked frame never fires `load`,
            // and the block itself is silent — this is the only page-side signal
            // that separates "never requested" from "requested and empty".
            var settled = false;
            frame.addEventListener('load', function () {
              settled = true;
              note(target, 'frame: load event fired');
            });
            setTimeout(function () {
              if (!settled) note(target, 'frame: no load event after 4s — blocked before request');
            }, 4000);
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

          // A `<meta http-equiv="Content-Security-Policy">` with a frame-src or
          // default-src directive blocks a custom-scheme frame outright — no
          // request, no error the page can see, just blank. Header-based CSP
          // cannot be reached from here; this only clears the meta form.
          function dropMetaCSP() {
            var metas = document.querySelectorAll(
              'meta[http-equiv="Content-Security-Policy" i]'
            );
            for (var i = 0; i < metas.length; i++) {
              var content = metas[i].getAttribute('content') || '';
              if (content.indexOf('frame-src') < 0 && content.indexOf('default-src') < 0) continue;
              metas[i].parentNode && metas[i].parentNode.removeChild(metas[i]);
              note(location.href, 'frame: removed meta CSP that would block the relay');
            }
          }

          function startObserving() {
            dropMetaCSP();
            scan(document);
            obs.observe(document.documentElement || document, {
              childList: true, subtree: true, attributes: true, attributeFilter: ['src']
            });
          }

          if (document.documentElement) startObserving();
          else document.addEventListener('DOMContentLoaded', startObserving);
        })();
        """#
        .replacingOccurrences(of: "__PANURA_SCHEME__", with: FrameSchemeHandler.scheme)
    }
}
