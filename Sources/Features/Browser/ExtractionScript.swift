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
      // URLs whose body proved them to be an HLS manifest.
      var confirmed = window.__panura_confirmed = window.__panura_confirmed || {};

      function post(payload) {
        try { window.webkit.messageHandlers.panura.postMessage(payload); } catch (e) {}
      }
      function absolute(u) {
        try { return new URL(String(u), location.href).href; } catch (e) { return String(u); }
      }
      // Playlist URIs are relative to the playlist, not to the page.
      function resolveAgainst(u, base) {
        try { return new URL(String(u), base || location.href).href; } catch (e) { return absolute(u); }
      }

      // Segments are never playable on their own. Extension alone can't tell a
      // segment from a manifest when both are extensionless, so we also learn
      // them for certain by reading the playlists we see (see scanPlaylist).
      var knownSegments = window.__panura_segments = window.__panura_segments || {};
      function isSegmentUrl(abs) {
        try {
          if (knownSegments[abs]) return true;
          var l = abs.toLowerCase().split('?')[0];
          if (/\.(ts|m4s|aac|mp3|m4a|cmfv|cmfa)$/.test(l)) return true;
          // seg-3-v1-a1, segment_12, frag12, chunk-4 …
          return /[\/\-_](seg|segment|frag|fragment|chunk)[\-_]?\d/.test(l);
        } catch (e) { return false; }
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

      function emit(abs, title, site, proven) {
        post({
          kind: 'video',
          url: abs,
          title: title || document.title || '',
          referer: refererFor(site),
          origin: location.origin,
          ua: navigator.userAgent,
          cookie: document.cookie || '',
          // A proven body IS an HLS manifest, so say so even with no site rule.
          // The player needs this: an extensionless or .txt playlist served as
          // text/plain gives libVLC nothing to identify it by.
          type: (site && site.type) || (proven ? 'hls' : ''),
          siteId: (site && site.id) || '',
          headers: (site && site.headers) || null
        });
      }

      // Diagnostics: record the verdict for anything media-shaped, so a URL that
      // never reaches the list can be told apart from one that was filtered.
      // Always sent — a flag injected at web-view creation cannot be toggled
      // later and never reaches cross-origin iframes. The native side decides
      // whether to keep these, and the media-shape filter keeps volume low.
      function dbg(url, verdict, src) {
        try {
          var s = String(url);
          if (!/\/hls\/|\/dash\/|\.m3u8|\.mpd|\.mp4|\.ts|\.m4s|seg|chunk|frag/i.test(s)) return;
          post({
            kind: 'debug', url: s.slice(0, 400), verdict: verdict,
            host: location.hostname, src: src || 'dom'
          });
        } catch (e) {}
      }

      // `proven` = the body came back starting with #EXTM3U, so this URL is a
      // manifest as a matter of fact. Proof outranks every URL-shape rule and
      // outranks strict mode: a stale `stream` pattern must not hide a real
      // stream we have already confirmed.
      // `src` names the hook that saw the URL — without it the log says what was
      // decided but not which layer (if any) ever observed the request.
      function report(url, title, proven, src) {
        try {
          if (!proven && !isVideoUrl(url)) { dbg(url, 'rejected: not video', src); return; }
          var abs = absolute(url);
          if (!proven && isSegmentUrl(abs)) { dbg(abs, 'rejected: segment', src); return; }
          if (reported[abs]) {
            // Nearly always the URL was seen at request time and only proved to
            // be a manifest when its body arrived. Upgrade the existing entry
            // rather than dropping the proof on the floor.
            if (proven && !confirmed[abs]) {
              confirmed[abs] = true;
              post({ kind: 'confirm', url: abs, type: 'hls' });
              dbg(abs, 'confirmed: hls manifest', src);
            }
            return;
          }
          reported[abs] = true;
          if (proven) confirmed[abs] = true;

          var site = matchedSite();
          var strict = !!(site && site.stream);

          if (!strict) { dbg(abs, 'emitted (no rule)', src); emit(abs, title, site, proven); return; }

          if (proven || matchesStream(site, abs)) {
            strictSatisfied = true;
            pending = [];               // the real stream won; drop the noise
            dbg(abs, proven ? 'emitted (proven manifest)' : 'emitted (rule match)', src);
            emit(abs, title, site, proven);
          } else {
            dbg(abs, 'held: no rule match', src);
            pending.push([abs, title]);
          }
        } catch (e) {}
      }

      // An HLS body identifies itself. Reading it tells us two things nothing
      // else can: that `sourceUrl` really is a manifest, and exactly which URLs
      // are segments — so they stop polluting the list.
      function scanPlaylist(text, sourceUrl) {
        try {
          if (!text || typeof text !== 'string') return;
          var head = text.slice(0, 512).replace(/^﻿/, '');
          if (head.replace(/^\s+/, '').lastIndexOf('#EXTM3U', 0) !== 0) return;

          if (sourceUrl) report(sourceUrl, '', true, 'playlist-body');

          var lines = text.split(/\r?\n/);
          var expectSegment = false;
          for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (!line) continue;
            if (line.charAt(0) === '#') {
              if (line.lastIndexOf('#EXTINF', 0) === 0) expectSegment = true;
              continue;
            }
            // Variant / audio playlists aren't emitted here: hls.js fetches them
            // next and they arrive proven, with their own post-redirect URL.
            if (expectSegment) {
              var segAbs = resolveAgainst(line, sourceUrl);
              knownSegments[segAbs] = true;
              // Reading the body is asynchronous, so the player can request the
              // first segment before we know it is one. Take it back.
              if (reported[segAbs]) {
                post({ kind: 'retract', url: segAbs });
                dbg(segAbs, 'retracted: segment', 'playlist-body');
              }
            }
            expectSegment = false;
          }
        } catch (e) {}
      }

      setTimeout(function () {
        try {
          if (strictSatisfied || !pending.length) return;
          var site = matchedSite();
          for (var i = 0; i < pending.length; i++) emit(pending[i][0], pending[i][1], site, false);
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
          try { report(String(url), '', false, 'xhr'); reportSub(String(url), '', ''); } catch (e) {}
          return origOpen.apply(this, arguments);
        };
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function () {
          try {
            var xhr = this;
            xhr.addEventListener('load', function () {
              try {
                var t = xhr.responseType;
                if (t !== '' && t !== 'text' && t !== 'json') return; // segments are arraybuffer
                var body = typeof xhr.response === 'string' ? xhr.response : xhr.responseText;
                // responseURL is the URL AFTER redirects — the only place the
                // real CDN manifest appears when the player requests it through
                // a redirecting front-end URL.
                var finalUrl = xhr.responseURL || '';
                scanPlaylist(body, finalUrl);
                if (finalUrl) report(finalUrl, '', false, 'xhr-response');
                scanSubsInText(body);
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
              if (u) { report(u, '', false, 'fetch'); reportSub(u, '', ''); }
            } catch (e) {}
            return origFetch.apply(this, arguments).then(function (response) {
              // Clone so the page still consumes its own body normally.
              try {
                // response.url is post-redirect, unlike the request URL above.
                var finalUrl = response.url || '';
                response.clone().text().then(function (body) {
                  scanPlaylist(body, finalUrl);
                  if (finalUrl) report(finalUrl, '', false, 'fetch-response');
                  scanSubsInText(body);
                }).catch(function () {});
              } catch (e) {}
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
              set: function (v) { try { if (v) report(String(v), '', false, 'src-setter'); } catch (e) {} return d.set.call(this, v); },
              get: d.get, configurable: true
            });
          }
        } catch (e) {}
      }
      hookSrc(HTMLMediaElement.prototype);
      hookSrc(HTMLSourceElement.prototype);

      // setAttribute('src', …) writes straight past the property setter above.
      // This is the common path on iOS: Safari plays HLS natively, so sites skip
      // hls.js entirely and hand the URL to a <video> — a request AVFoundation
      // makes, which no XHR/fetch hook can ever observe.
      try {
        var origSetAttr = Element.prototype.setAttribute;
        Element.prototype.setAttribute = function (name, value) {
          try {
            var n = String(name).toLowerCase();
            if (value && (n === 'src' || n === 'data-src')) {
              var tag = (this.tagName || '').toUpperCase();
              if (tag === 'VIDEO' || tag === 'SOURCE' || tag === 'AUDIO') report(String(value), '', false, 'setAttribute');
            }
          } catch (e) {}
          return origSetAttr.apply(this, arguments);
        };
      } catch (e) {}

      // Media events are the backstop: they fire the moment an element starts
      // fetching, with currentSrc already resolved, no matter how the src was
      // set or how late it happened. Capture phase so we see them in any subtree.
      try {
        ['loadstart', 'loadedmetadata', 'durationchange', 'canplay', 'playing']
          .forEach(function (ev) {
            document.addEventListener(ev, function (e) {
              try {
                var t = e.target;
                if (!t || !t.tagName) return;
                var tag = t.tagName.toUpperCase();
                if (tag !== 'VIDEO' && tag !== 'AUDIO' && tag !== 'SOURCE') return;
                var s = t.currentSrc || t.src || t.getAttribute('src');
                if (s) report(s, '', false, 'media-event:' + ev);
              } catch (e2) {}
            }, true);
          });
      } catch (e) {}

      // load() resolves <source> children into currentSrc.
      try {
        var origLoad = HTMLMediaElement.prototype.load;
        HTMLMediaElement.prototype.load = function () {
          var r = origLoad.apply(this, arguments);
          try {
            var s = this.currentSrc || this.src;
            if (s) report(s, '', false, 'load()');
          } catch (e) {}
          return r;
        };
      } catch (e) {}

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
            if (s) report(s, '', false, 'play()');
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
          if (s) report(s, '', false, 'dom-scan');
        } catch (e) {}
      }

      function scan() {
        try {
          if (window.jwplayer) {
            var pl = jwplayer().getPlaylist();
            if (pl && pl[0] && pl[0].sources) pl[0].sources.forEach(function (s) { report(s.file, '', false, 'jwplayer'); });
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
              while ((m = pat.exec(text)) !== null && m[1]) report(m[1], '', false, 'inline-script');
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
              // An existing <video> getting a new src is an attribute mutation,
              // not a childList one — invisible without this.
              if (m.type === 'attributes') { scanElement(m.target); return; }
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
            document.documentElement || document,
            { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] }
          );
        }
      } catch (e) {}

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', scan, false);
      }
      scan();
      // Keep watching after the first 30s, just less often: the user may press
      // play at any point, and a stopped scanner sees nothing.
      var n = 0, iv = setInterval(function () {
        scan();
        if (++n > 30) { clearInterval(iv); setInterval(scan, 3000); }
      }, 1000);
    })();
    """#
}
