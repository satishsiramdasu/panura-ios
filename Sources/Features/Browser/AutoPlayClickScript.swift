import Foundation

/// Port of Android's `AUTO_PLAY_CLICK_JS`.
///
/// For sites that load nothing until a play click. There is no `src` to preload
/// and — on iOS, where there is no `shouldInterceptRequest` at all — nothing to
/// intercept either: the click handler is what fetches the playlist. So press it
/// ourselves, and let the existing XHR/fetch hooks see the result.
///
/// Injected into EVERY frame at document start (`forMainFrameOnly: false`),
/// because the player is nearly always inside a cross-origin iframe that
/// `evaluateJavaScript` cannot reach.
///
/// The popups these clicks would otherwise trigger are already handled twice
/// over: `javaScriptCanOpenWindowsAutomatically` is off, and a synthetic click
/// carries no user activation, so the engine blocks `window.open` outright. We
/// need the fetch, not playback — which is what makes this work at all.
enum AutoPlayClickScript {
    static let source = #"""
    (function () {
      if (window.__panuraAutoClick) return;
      window.__panuraAutoClick = true;

      // Never poke inside an ad frame: there the "play button" is the ad.
      var AD_HOSTS = /admob\.com|googlesyndication\.com|doubleclick\.net|googleadservices\.com|imasdk\.googleapis\.com|amazon-adsystem\.com|adnxs\.com|rubiconproject\.com|pubmatic\.com|openx\.net|criteo\.com|applovin\.com|ironsrc\.com|unity3d\.com|mopub\.com|inmobi\.com|vungle\.com|chartboost\.com/i;
      try { if (AD_HOSTS.test(location.href)) return; } catch (e) { return; }

      // Never on a search page either, and Google above all — which is where
      // most sessions begin.
      //
      // Nothing here waits on a play click, so there is nothing to gain, and
      // the selectors below are actively dangerous on a results page: it is
      // full of inline video previews and controls carrying "play" in a label,
      // so the script clicks a result and navigates the page out from under
      // whoever was reading it.
      var SKIP_HOSTS = /(^|\.)google\.[a-z]{2,}(\.[a-z]{2,})?$|(^|\.)bing\.com$|(^|\.)duckduckgo\.com$|(^|\.)ecosia\.org$|(^|\.)startpage\.com$|(^|\.)qwant\.com$|(^|\.)yandex\.[a-z]{2,}$|(^|\.)search\.yahoo\.com$|(^|\.)search\.brave\.com$|(^|\.)youtube\.com$|(^|\.)youtu\.be$/i;
      try { if (SKIP_HOSTS.test(location.hostname)) return; } catch (e) { return; }

      // Players mount late and often replace their own controls, so try more
      // than once — but a fixed few times, never a loop.
      var ROUNDS = [900, 2200, 4000];
      var MAX_PER_ROUND = 2;
      var poked = [];

      // Most specific first: a real player's own control beats a guess from a
      // class-name substring.
      var SELECTORS = [
        '.jw-icon-display', '.vjs-big-play-button', '.plyr__control--overlaid',
        '.fp-play', '.play-button', '.playbutton', '.btn-play', '.video-play',
        '[class*="play-btn"]', '[class*="playBtn"]', '[class*="play_button"]',
        '[id*="play-btn"]', '[id*="playbutton"]',
        '[aria-label*="play" i]', '[title*="play" i]',
        '.jw-media', '.video-js', 'video'
      ];

      function safeTarget(el) {
        try {
          if (!el || poked.indexOf(el) !== -1) return false;
          // A link dressed as a play button: clicking it leaves the page, which
          // is the opposite of what this is for.
          var a = el.closest ? el.closest('a[href]') : null;
          if (a) {
            var h = (a.getAttribute('href') || '').trim();
            if (h && h !== '#' && h.toLowerCase().indexOf('javascript:') !== 0) return false;
          }
          var r = el.getBoundingClientRect();
          if (r.width < 24 || r.height < 24) return false;
          var st = window.getComputedStyle(el);
          if (!st || st.display === 'none' || st.visibility === 'hidden') return false;
          if (parseFloat(st.opacity || '1') === 0) return false;
          return true;
        } catch (e) { return false; }
      }

      function poke(el) {
        poked.push(el);
        try {
          var r = el.getBoundingClientRect();
          var opts = {
            bubbles: true, cancelable: true, view: window,
            clientX: r.left + r.width / 2, clientY: r.top + r.height / 2
          };
          // Players listen at different layers — some on pointer, some only on
          // click, and mobile players often on touch — so send the whole
          // sequence a finger would produce.
          ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (t) {
            try { el.dispatchEvent(new MouseEvent(t, opts)); } catch (e) {}
          });
          try { if (el.click) el.click(); } catch (e) {}
        } catch (e) {}
      }

      // If a video is already loading or playing, the page did the work itself
      // and there is nothing to press.
      function alreadyLoading() {
        try {
          var vs = document.querySelectorAll('video');
          for (var i = 0; i < vs.length; i++) {
            var v = vs[i];
            if (v.currentSrc || v.readyState > 0 || !v.paused) return true;
          }
        } catch (e) {}
        return false;
      }

      function attempt() {
        if (alreadyLoading()) return;
        var hits = 0;
        for (var i = 0; i < SELECTORS.length && hits < MAX_PER_ROUND; i++) {
          var list;
          try { list = document.querySelectorAll(SELECTORS[i]); } catch (e) { continue; }
          for (var j = 0; j < list.length && hits < MAX_PER_ROUND; j++) {
            if (safeTarget(list[j])) { poke(list[j]); hits++; }
          }
        }
      }

      function schedule() { ROUNDS.forEach(function (ms) { setTimeout(attempt, ms); }); }

      if (document.readyState === 'complete' || document.readyState === 'interactive') {
        schedule();
      } else {
        window.addEventListener('DOMContentLoaded', schedule);
      }
    })();
    """#
}
