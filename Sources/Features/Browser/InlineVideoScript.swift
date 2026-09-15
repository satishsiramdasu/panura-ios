import Foundation

/// Keeps a page's video in the page when it starts, without taking full screen
/// away from the user.
///
/// On iPhone a `<video>` without `playsinline` goes to the system full-screen
/// player the moment it starts, whatever `allowsInlineMediaPlayback` says —
/// that setting only permits inline playback, the page still has to ask. Many
/// players never do, and others call the full-screen API from their own play
/// button. Either way pressing play lands the user in Apple's player instead
/// of the page.
///
/// So every video is marked `playsinline` before it can play, and a full-screen
/// request that arrives within `WINDOW` of playback starting — the player doing
/// it by itself — is ignored, or ended if it began anyway. Full screen asked for
/// later is a separate action: the site's full-screen button, or the native
/// one in the video's controls, works as normal.
///
/// Detection is unaffected — the sniffer watches requests and media events,
/// none of which depend on where the video is drawn.
///
/// Every frame, at document start, like the other scripts: the player is
/// nearly always inside a cross-origin iframe.
enum InlineVideoScript {
    static let source = #"""
    (function () {
      if (window.__panuraInline) return;
      window.__panuraInline = true;

      // How long after playback starts a full-screen request counts as the
      // player's own doing rather than the user's.
      var WINDOW = 1500;
      var lastPlay = 0;
      function playing() { lastPlay = Date.now(); }
      function automatic() { return Date.now() - lastPlay < WINDOW; }

      function inline(v) {
        try {
          if (!v || v.tagName !== 'VIDEO') return;
          if (!v.hasAttribute('playsinline')) v.setAttribute('playsinline', '');
          if (!v.hasAttribute('webkit-playsinline')) v.setAttribute('webkit-playsinline', '');
          v.playsInline = true;
        } catch (e) {}
      }

      function sweep(root) {
        try {
          if (root.tagName === 'VIDEO') inline(root);
          if (root.querySelectorAll) {
            var list = root.querySelectorAll('video');
            for (var i = 0; i < list.length; i++) inline(list[i]);
          }
        } catch (e) {}
      }

      // The attribute is read when playback starts, so setting it inside play()
      // covers a video created and started in the same tick.
      try {
        var play = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function () {
          inline(this);
          playing();
          return play.apply(this, arguments);
        };
      } catch (e) {}
      // Native controls and autoplay start without calling play().
      document.addEventListener('play', function (e) { inline(e.target); playing(); }, true);

      // Full-screen requests pass through unless they ride on the start of
      // playback. Promise-returning ones resolve when skipped, so a player
      // awaiting them carries on instead of throwing.
      function guard(proto, name, returnsPromise) {
        try {
          var original = proto[name];
          if (typeof original !== 'function') return;
          proto[name] = function () {
            if (automatic()) return returnsPromise ? Promise.resolve() : undefined;
            return original.apply(this, arguments);
          };
        } catch (e) {}
      }
      guard(HTMLVideoElement.prototype, 'webkitEnterFullscreen', false);
      guard(HTMLVideoElement.prototype, 'webkitEnterFullScreen', false);
      guard(Element.prototype, 'requestFullscreen', true);
      guard(Element.prototype, 'webkitRequestFullscreen', false);
      guard(Element.prototype, 'webkitRequestFullScreen', false);

      // A path none of the above sees that still gets there at the start of
      // playback is brought straight back. Later, the user meant it.
      document.addEventListener('webkitbeginfullscreen', function (e) {
        if (!automatic()) return;
        try { if (e.target && e.target.webkitExitFullscreen) e.target.webkitExitFullscreen(); } catch (x) {}
      }, true);

      function observe() {
        sweep(document);
        try {
          new MutationObserver(function (records) {
            for (var r = 0; r < records.length; r++) {
              var added = records[r].addedNodes;
              for (var n = 0; n < added.length; n++) {
                if (added[n].nodeType === 1) sweep(added[n]);
              }
            }
          }).observe(document.documentElement, { childList: true, subtree: true });
        } catch (e) {}
      }
      if (document.documentElement) observe();
      else document.addEventListener('DOMContentLoaded', observe);
    })();
    """#
}
