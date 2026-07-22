import Foundation

/// Full port of the Android generic sniffer (`BROWSER_SNIFFER_JS` + `SCANNER_JS`),
/// rebridged from the `PanuraExtractor` JavascriptInterface to
/// `webkit.messageHandlers.panura`.
///
/// Injected into EVERY frame at document start — most sites play inside a
/// cross-origin embed iframe, and the hooks must be installed before page
/// scripts fire their requests.
///
/// Layers, in order of what actually catches modern sites:
///  1. XHR / fetch overrides — the manifest request itself (MSE sites expose
///     only a `blob:` in the DOM, so this is the only way to see the real URL).
///  2. `HTMLMediaElement.src` / `HTMLSourceElement.src` setters + `play()` —
///     programmatic assignment.
///  3. DOM + inline-script scanning, re-run by a MutationObserver for lazily
///     rendered players.
///  4. Subtitle capture, including scanning XHR/fetch response *bodies* — how
///     players that keep captions disabled advertise their track list.
///
/// Every hit carries the gating context (referer/origin/UA/cookie) so the
/// native player can replay the request.
enum ExtractionScript {
    static let source = #"""
    (function () {
      if (window.__panura_sniffer) return;
      window.__panura_sniffer = true;
      var reported = window.__panura_reported = window.__panura_reported || {};
      var subsReported = window.__panura_subs_reported = window.__panura_subs_reported || {};

      function post(payload) {
        try { window.webkit.messageHandlers.panura.postMessage(payload); } catch (e) {}
      }
      function absolute(u) {
        try { return new URL(String(u), location.href).href; } catch (e) { return String(u); }
      }

      // ── URL classification (ported from Android isVideoUrl) ────────────────
      function isVideoUrl(url) {
        if (!url || typeof url !== 'string') return false;
        if (url.indexOf('blob:') === 0 || url.indexOf('data:') === 0) return false;
        var lower = url.toLowerCase();
        var l = lower.split('?')[0];
        if (l.indexOf('127.0.0.1') !== -1) return false; // our own proxy
        if (lower.indexOf('bytestart=') !== -1 && lower.indexOf('byteend=') !== -1) return false;
        if (/\.(js|mjs|css|json|woff|woff2|ts|m4s|png|jpg|jpeg|svg|gif|ico|webp|xml)$/.test(l)) return false;
        if (/\.txt$/.test(l) && (l.indexOf('/v4/') !== -1 || l.indexOf('master') !== -1 ||
            l.indexOf('index') !== -1 || l.indexOf('playlist') !== -1 || l.indexOf('/hls') !== -1)) return true;
        if (/\.(m3u8|mp4|webm|mkv|mpd)$/.test(l)) return true;
        if (l.indexOf('/hls/') !== -1 || l.indexOf('/dash/') !== -1) return true;
        if (lower.indexOf('.m3u8') !== -1 || lower.indexOf('.mpd') !== -1 ||
            lower.indexOf('.mp4') !== -1) return true;
        // A site rule's stream pattern is authoritative — it may well point at a
        // URL none of the generic rules above would accept.
        if (matchesStream(matchedSite(), url)) return true;
        // Extra regexes pushed from the remote manifest.
        return streamPatterns().some(function (p) {
          try { return new RegExp(p).test(url); } catch (e) { return false; }
        });
      }

      // ── Manifest site rules ────────────────────────────────────────────────
      // First entry whose host regex matches THIS frame's hostname. Resolved on
      // each call (the manifest is injected asynchronously and may land after
      // the first URL is classified).
      function matchedSite() {
        try {
          var sites = window.__panuraSites;
          if (!sites || !sites.length) return null;
          var h = location.hostname;
          for (var i = 0; i < sites.length; i++) {
            var s = sites[i];
            if (!s || !s.host) continue;
            try { if (new RegExp(s.host).test(h)) return s; } catch (e) {}
          }
        } catch (e) {}
        return null;
      }

      function matchesStream(site, url) {
        if (!site || !site.stream) return false;
        try { return new RegExp(site.stream).test(url); } catch (e) { return false; }
      }

      // Referer exactly as the rule requires — the form matters: some CDNs are
      // validated against the origin root, not the full page URL.
      function refererFor(site) {
        var mode = (site && site.referer) || 'page';
        if (mode === 'none') return '';
        if (mode === 'origin') return location.origin + '/';
        return location.href;
      }

      // Patterns for THIS frame's host (or its parent domain). Resolved on each
      // call rather than memoized, because the manifest is injected
      // asynchronously and may land after the first URL is classified.
      function streamPatterns() {
        var out = window.__panuraStreamPatterns || [];
        try {
          var map = window.__panuraStreamPatternMap;
          if (map) {
            var h = location.hostname.replace(/^www\./, '');
            var parent = h.indexOf('.') !== -1 ? h.substring(h.indexOf('.') + 1) : '';
            var hit = map[h] || (parent ? map[parent] : null);
            if (hit) out = out.concat([hit]);
          }
        } catch (e) {}
        return out;
      }

      // Strict mode: when the matched rule declares a stream pattern we report
      // ONLY those, so the list is the real stream instead of every candidate.
      // Non-matches are held here and flushed if no strict hit arrives in time —
      // a stale pattern must never leave a site dead.
      var pending = [];
      var strictSatisfied = false;
      var FALLBACK_MS = 8000;

      function emit(abs, title, site) {
        post({
          kind: 'video',
          url: abs,
          title: title || document.title || '',
          referer: refererFor(site),
          origin: location.origin,
          ua: navigator.userAgent,
          cookie: document.cookie || '',
          type: (site && site.type) || '',
          siteId: (site && site.id) || '',
          headers: (site && site.headers) || null
        });
      }

      function report(url, title) {
        try {
          if (!isVideoUrl(url)) return;
          var abs = absolute(url);
          if (reported[abs]) return;
          reported[abs] = true;

          var site = matchedSite();
          var strict = !!(site && site.stream);

          if (!strict) { emit(abs, title, site); return; }

          if (matchesStream(site, abs)) {
            strictSatisfied = true;
            pending = [];               // the real stream won; drop the noise
            emit(abs, title, site);
          } else {
            pending.push([abs, title]);
          }
        } catch (e) {}
      }

      setTimeout(function () {
        try {
          if (strictSatisfied || !pending.length) return;
          var site = matchedSite();
          for (var i = 0; i < pending.length; i++) emit(pending[i][0], pending[i][1], site);
          pending = [];
        } catch (e) {}
      }, FALLBACK_MS);

      // ── Subtitles ──────────────────────────────────────────────────────────
      function isSubUrl(url) {
        if (!url || typeof url !== 'string') return false;
        if (url.indexOf('blob:') === 0 || url.indexOf('data:') === 0) return false;
        var l = url.toLowerCase().split('?')[0].split('#')[0];
        if (!/\.(vtt|srt|ass|ssa|ttml|dfxp)$/.test(l)) return false;
        // .vtt is also used for thumbnail sprites / storyboards / chapters.
        var file = l.split('/').pop();
        return !/(thumb|thumbs|thumbnail|sprite|storyboard|chapter|preview|poster|seek)/.test(file);
      }
      function reportSub(url, label, lang) {
        try {
          if (!isSubUrl(url)) return;
          var abs = absolute(url);
          if (subsReported[abs]) return;
          subsReported[abs] = true;
          post({ kind: 'subtitle', url: abs, label: label || '', lang: lang || '' });
        } catch (e) {}
      }

      // Players that keep captions off still learn the track list from a JSON
      // payload first — so scan response bodies, not just request URLs.
      function scanSubsInText(text) {
        try {
          if (!text || text.length < 8 || text.length > 400000) return;
          if (text.indexOf('.vtt') === -1 && text.indexOf('.srt') === -1 &&
              text.indexOf('.ass') === -1 && text.indexOf('.ttml') === -1) return;
          var objPat = /\{[^{}]*?["'`]?(?:file|src|url|link)["'`]?\s*[:=]\s*["'`]([^"'`\s]+?\.(?:vtt|srt|ass|ssa|ttml|dfxp)[^"'`\s]*)["'`][^{}]*?\}/gi;
          var labelPat = /["'`]?(?:label|title|name|display)["'`]?\s*[:=]\s*["'`]([^"'`]{1,40})["'`]/i;
          var langPat = /["'`]?(?:language|lang|srclang|code)["'`]?\s*[:=]\s*["'`]([a-zA-Z\-]{2,8})["'`]/i;
          var m;
          objPat.lastIndex = 0;
          while ((m = objPat.exec(text)) !== null) {
            var blob = m[0], u = m[1];
            var lm = labelPat.exec(blob), gm = langPat.exec(blob);
            reportSub(u, lm ? lm[1] : '', gm ? gm[1] : '');
          }
          // PlayerJS "[English]https://…/en.vtt,[Spanish]…" — labels in brackets.
          var pjsPat = /\[([^\[\]]{1,30})\]\s*(https?:\/\/[^\s,"'`\[\]]+?\.(?:vtt|srt|ass|ssa|ttml|dfxp)(?:\?[^\s,"'`\[\]]*)?)/gi;
          pjsPat.lastIndex = 0;
          while ((m = pjsPat.exec(text)) !== null) reportSub(m[2], m[1], '');
          // Shaka addTextTrack('…/en.vtt', 'en', …) — positional args.
          var shakaPat = /addTextTrack(?:Async)?\s*\(\s*["'`]([^"'`]+?\.(?:vtt|srt|ass|ssa|ttml|dfxp)[^"'`]*)["'`]\s*,\s*["'`]([a-zA-Z\-]{2,8})["'`]/gi;
          shakaPat.lastIndex = 0;
          while ((m = shakaPat.exec(text)) !== null) reportSub(m[1], '', m[2]);
          var barePat = /["'`(\s,](https?:\/\/[^"'`\s,)]{6,}?\.(?:vtt|srt|ass|ssa|ttml|dfxp)(?:\?[^"'`\s,)]*)?)/gi;
          barePat.lastIndex = 0;
          while ((m = barePat.exec(text)) !== null) reportSub(m[1], '', '');
        } catch (e) {}
      }

      // ── window.chrome stub ─────────────────────────────────────────────────
      // Sites gate rich UI behind `if (window.chrome)`; without it they serve a
      // degraded page (missing hero images, broken lazy loaders).
      if (!window.chrome) {
        var noop = function () {};
        var listener = { addListener: noop, removeListener: noop, hasListeners: function () { return false; } };
        window.chrome = {
          runtime: {
            id: undefined,
            connect: function () { return { postMessage: noop, disconnect: noop, onMessage: listener, onDisconnect: listener }; },
            sendMessage: noop, onMessage: listener, onConnect: listener,
            lastError: undefined, getManifest: function () { return {}; }, getURL: function (p) { return p; }
          },
          loadTimes: function () { return {}; },
          csi: function () { return {}; },
          app: {
            isInstalled: false, getDetails: function () { return null; },
            getIsInstalled: function (c) { if (c) c(false); },
            installState: function (c) { if (c) c('not_installed'); },
            runningState: function () { return 'cannot_run'; }
          }
        };
      }

      // ── Network hooks ──────────────────────────────────────────────────────
      try {
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { report(String(url)); reportSub(String(url), '', ''); } catch (e) {}
          return origOpen.apply(this, arguments);
        };
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function () {
          try {
            var xhr = this;
            xhr.addEventListener('load', function () {
              try {
                var t = xhr.responseType;
                if (t === '' || t === 'text' || t === 'json') {
                  scanSubsInText(typeof xhr.response === 'string' ? xhr.response : xhr.responseText);
                }
              } catch (e) {}
            }, false);
          } catch (e) {}
          return origSend.apply(this, arguments);
        };
      } catch (e) {}

      try {
        var origFetch = window.fetch;
        if (origFetch) {
          window.fetch = function (resource) {
            try {
              var u = typeof resource === 'string' ? resource : (resource && resource.url) ? resource.url : '';
              if (u) { report(u); reportSub(u, '', ''); }
            } catch (e) {}
            return origFetch.apply(this, arguments).then(function (response) {
              // Clone so the page still consumes its own body normally.
              try { response.clone().text().then(scanSubsInText).catch(function () {}); } catch (e) {}
              return response;
            });
          };
        }
      } catch (e) {}

      // ── Programmatic src assignment ────────────────────────────────────────
      function hookSrc(proto) {
        try {
          var d = Object.getOwnPropertyDescriptor(proto, 'src');
          if (d && d.set) {
            Object.defineProperty(proto, 'src', {
              set: function (v) { try { if (v) report(String(v)); } catch (e) {} return d.set.call(this, v); },
              get: d.get, configurable: true
            });
          }
        } catch (e) {}
      }
      hookSrc(HTMLMediaElement.prototype);
      hookSrc(HTMLSourceElement.prototype);

      try {
        var trkDesc = Object.getOwnPropertyDescriptor(HTMLTrackElement.prototype, 'src');
        if (trkDesc && trkDesc.set) {
          Object.defineProperty(HTMLTrackElement.prototype, 'src', {
            set: function (v) {
              try { if (v) reportSub(String(v), this.label || '', this.srclang || ''); } catch (e) {}
              return trkDesc.set.call(this, v);
            },
            get: trkDesc.get, configurable: true
          });
        }
      } catch (e) {}

      // play() fires at the exact moment playback is requested — currentSrc is
      // resolved by then even when src was never set directly.
      try {
        var origPlay = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function () {
          try {
            var s = this.currentSrc || this.src;
            if (s) report(s);
          } catch (e) {}
          return origPlay.apply(this, arguments);
        };
      } catch (e) {}

      // MediaSession metadata — real title/artwork for the detected item.
      try {
        var msMeta = Object.getOwnPropertyDescriptor(MediaSession.prototype, 'metadata');
        if (msMeta && msMeta.set) {
          var msSet = msMeta.set;
          Object.defineProperty(MediaSession.prototype, 'metadata', {
            set: function (val) {
              try {
                if (val) {
                  var art = '';
                  try { if (val.artwork && val.artwork.length) art = val.artwork[val.artwork.length - 1].src || ''; } catch (e) {}
                  post({ kind: 'meta', title: val.title || '', artist: val.artist || '', artwork: art });
                }
              } catch (e) {}
              return msSet.call(this, val);
            },
            get: msMeta.get, configurable: true
          });
        }
      } catch (e) {}

      // ── DOM + inline script scanning ───────────────────────────────────────
      var scriptPatterns = [
        /["'`](https?:[^"'`\s]{10,}\.m3u8[^"'`\s]*)/g,
        /["'`](https?:[^"'`\s]{10,}\.mp4[^"'`\s]*)/g,
        /["'`](https?:[^"'`\s]{10,}\.mpd[^"'`\s]*)/g,
        /["'`](https?:[^"'`\s]{10,}\/hls\/[^"'`\s]{5,})/g,
        /["'`](https?:[^"'`\s]{10,}\/dash\/[^"'`\s]{5,})/g,
        /(?:file|src|url|stream|source|hls|video|media)\s*[=:]\s*["'`](https?:[^"'`\s]{10,})/gi,
        /(?:hlsUrl|streamUrl|videoUrl|m3u8Url|playUrl|masterUrl|mediaUrl|manifestUrl)\s*[=:]\s*["'`](https?:\/\/[^"'`\s]{10,})/gi,
        /hls\.loadSource\(["'`](https?:[^"'`\s]+)["'`]\)/g,
        /player\.src\(\s*\{[^}]*src\s*:\s*["'`](https?:[^"'`\s]+)/g
      ];

      function scanTrack(el) {
        try {
          var kind = (el.getAttribute('kind') || '').toLowerCase();
          if (kind && kind !== 'subtitles' && kind !== 'captions') return;
          var s = el.src || el.getAttribute('src');
          if (s) reportSub(s, el.getAttribute('label') || '', el.getAttribute('srclang') || '');
        } catch (e) {}
      }
      function scanElement(el) {
        try {
          var s = el.currentSrc || el.src || el.getAttribute('src');
          if (s) report(s);
        } catch (e) {}
      }

      function scan() {
        try {
          if (window.jwplayer) {
            var pl = jwplayer().getPlaylist();
            if (pl && pl[0] && pl[0].sources) pl[0].sources.forEach(function (s) { report(s.file); });
          }
        } catch (e) {}
        try { document.querySelectorAll('video, source').forEach(scanElement); } catch (e) {}
        try { document.querySelectorAll('track').forEach(scanTrack); } catch (e) {}
        try {
          document.querySelectorAll('script:not([src])').forEach(function (s) {
            var text = s.textContent || '';
            if (text.length > 500000) return;
            scriptPatterns.forEach(function (pat) {
              pat.lastIndex = 0;
              var m;
              while ((m = pat.exec(text)) !== null && m[1]) report(m[1]);
            });
            scanSubsInText(text);
          });
        } catch (e) {}
      }

      // Players render lazily (React/Vue hydration, ad wrappers) — observe.
      try {
        if (!window.__panura_observer) {
          window.__panura_observer = new MutationObserver(function (muts) {
            muts.forEach(function (m) {
              m.addedNodes.forEach(function (n) {
                if (!n.tagName) return;
                var tag = n.tagName.toUpperCase();
                if (tag === 'VIDEO' || tag === 'SOURCE') scanElement(n);
                if (tag === 'TRACK') scanTrack(n);
                if (n.querySelectorAll) {
                  try { n.querySelectorAll('video, source').forEach(scanElement); } catch (e) {}
                  try { n.querySelectorAll('track').forEach(scanTrack); } catch (e) {}
                }
              });
            });
          });
          window.__panura_observer.observe(
            document.documentElement || document, { childList: true, subtree: true }
          );
        }
      } catch (e) {}

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', scan, false);
      }
      scan();
      var n = 0, iv = setInterval(function () { scan(); if (++n > 20) clearInterval(iv); }, 1000);
    })();
    """#
}
