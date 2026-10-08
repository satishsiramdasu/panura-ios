import Foundation

/// Makes a page's own full-screen video behave: tells the app when the system
/// player opens, and gets the page to measure the screen it is actually on.
///
/// Two problems, one script, because both hang off the same event.
///
/// **Orientation.** `WKWebView.fullscreenState` reports the HTML Fullscreen API
/// and nothing else — what a desktop-layout site uses for its own player. A
/// mobile site usually hands a bare `<video>` to the system player instead, and
/// that path raises `webkitbeginfullscreen`, which no KVO observer ever sees. So
/// the app stayed pinned to portrait for exactly the sites most likely to be
/// opened on a phone. These events are reported so one rule can cover both
/// paths.
///
/// **Height.** A player that sized itself from `innerHeight` before the
/// transition keeps that number afterwards and comes up short by whatever the
/// window gained — on a notched phone, the home indicator, which reads as a
/// black band under the video. Nothing tells the page to measure again, so this
/// does: twice, because the window is still animating when the event fires and
/// a player that measures during the animation gets the wrong answer twice over.
///
/// It reports and re-measures. It never takes full screen away from anyone —
/// that is `InlineVideoScript`, and it is what `block_page_fullscreen` governs.
/// This one is unconditional.
///
/// Every frame, at document start: the player is nearly always inside an iframe,
/// and only the frame that owns the `<video>` sees its events.
enum PageFullscreenScript {
    static let source = #"""
    (function () {
      if (window.__panuraFullscreen) return;
      window.__panuraFullscreen = true;

      function tell(state) {
        try {
          window.webkit.messageHandlers.panura.postMessage({
            kind: 'fullscreen', state: state
          });
        } catch (e) {}
      }

      // A page laid out for a window that stopped short of the safe area keeps
      // that size in full screen. `viewport-fit=cover` lets it have the whole
      // display, and makes env(safe-area-inset-*) resolve for the sites that
      // ask. Left alone if the page already has an opinion.
      function cover() {
        try {
          var meta = document.querySelector('meta[name="viewport"]');
          if (!meta) return;
          var content = meta.getAttribute('content') || '';
          if (/viewport-fit/i.test(content)) return;
          meta.setAttribute('content', content + (content ? ',' : '') + 'viewport-fit=cover');
        } catch (e) {}
      }

      // Players re-size themselves on resize, so give them one. The second is
      // for the ones that animate into place and would otherwise measure
      // halfway through their own transition.
      function remeasure() {
        try {
          window.dispatchEvent(new Event('resize'));
          setTimeout(function () {
            try { window.dispatchEvent(new Event('resize')); } catch (e) {}
          }, 400);
        } catch (e) {}
      }

      // Capture, because these fire on the <video> and do not bubble.
      document.addEventListener('webkitbeginfullscreen', function () {
        tell('begin');
        remeasure();
      }, true);
      document.addEventListener('webkitendfullscreen', function () {
        tell('end');
        remeasure();
      }, true);

      // The HTML Fullscreen API half. The app already watches `fullscreenState`
      // for the orientation there, so this only has to do the measuring.
      document.addEventListener('fullscreenchange', remeasure, true);
      document.addEventListener('webkitfullscreenchange', remeasure, true);

      if (document.head) cover();
      else document.addEventListener('DOMContentLoaded', cover);
    })();
    """#
}
