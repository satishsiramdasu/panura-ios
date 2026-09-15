import Foundation

/// Keeps a page's own video inside the page.
///
/// On iPhone a `<video>` without `playsinline` goes to the system full-screen
/// player the moment it starts, whatever `allowsInlineMediaPlayback` says —
/// that setting only permits inline playback, the page still has to ask. Many
/// players never do, and others call the full-screen API from their play
/// button. Either way the user lands in Apple's player, a second player next
/// to ours, on the way to the stream we are about to detect and open properly.
///
/// So: every video is marked `playsinline` before it can play, the element and
/// video full-screen calls do nothing, and a full screen that starts anyway is
/// ended at once. Detection is unaffected — the sniffer watches requests and
/// media events, none of which depend on where the video is drawn.
///
/// Every frame, at document start, like the other scripts: the player is
/// nearly always inside a cross-origin iframe.
enum InlineVideoScript {
    static let source = #"""
    (function () {
      if (window.__panuraInline) return;
      window.__panuraInline = true;

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
          return play.apply(this, arguments);
        };
      } catch (e) {}

      // Full-screen requests become no-ops. Promise-returning ones resolve, so a
      // player awaiting them carries on instead of throwing.
      try {
        var resolved = function () { return Promise.resolve(); };
        var nothing = function () {};
        HTMLVideoElement.prototype.webkitEnterFullscreen = nothing;
        HTMLVideoElement.prototype.webkitEnterFullScreen = nothing;
        Element.prototype.requestFullscreen = resolved;
        Element.prototype.webkitRequestFullscreen = nothing;
        Element.prototype.webkitRequestFullScreen = nothing;
      } catch (e) {}

      // Anything that still gets there — a path none of the above sees — is
      // brought straight back.
      document.addEventListener('webkitbeginfullscreen', function (e) {
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
