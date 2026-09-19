import Foundation

/// Stops a long press on a page from raising iOS's own menu — the text
/// selection handles with Copy / Look Up / Share, and the Copy Link / Open in
/// New Tab sheet on a link or image.
///
/// This is the CSS half. The link and image menu is killed natively instead, in
/// `WebViewContainer` (`allowsLinkPreview = false` plus a `WKUIDelegate` that
/// returns no context-menu configuration), because doing that in CSS only works
/// where a page has not overridden it, while the delegate always wins. Text
/// selection has no such API and is only reachable from the page's styles.
///
/// **Form fields keep both.** `-webkit-user-select: none` on an `<input>` means
/// a login box cannot be selected, corrected, or pasted into, and disabling the
/// callout there takes away the Paste menu itself — a browser that cannot paste
/// a password is broken. So every editable element has them restored explicitly
/// after the blanket rule.
///
/// Injected at document start in every frame, like the other scripts. The style
/// goes on `documentElement` rather than `head`, which does not reliably exist
/// that early, and is re-applied once the document is parsed in case the page
/// replaced the element wholesale.
enum LongPressScript {
    static let source = #"""
    (function () {
      if (window.__panuraNoCallout) return;
      window.__panuraNoCallout = true;

      var CSS = [
        '*, *::before, *::after {',
        '  -webkit-touch-callout: none !important;',
        '  -webkit-user-select: none !important;',
        '  user-select: none !important;',
        '}',
        // Everything editable gets both back. A blanket rule that also silenced
        // form fields would stop a password being pasted, which is worse than
        // the menu this script exists to remove.
        'input, textarea, select, [contenteditable], [contenteditable] * {',
        '  -webkit-touch-callout: default !important;',
        '  -webkit-user-select: text !important;',
        '  user-select: text !important;',
        '}',
      ].join('\n');

      function apply() {
        if (document.getElementById('__panura_no_callout')) return;
        var root = document.head || document.documentElement;
        if (!root) return;
        var style = document.createElement('style');
        style.id = '__panura_no_callout';
        style.textContent = CSS;
        root.appendChild(style);
      }

      apply();
      document.addEventListener('DOMContentLoaded', apply);
    })();
    """#
}
