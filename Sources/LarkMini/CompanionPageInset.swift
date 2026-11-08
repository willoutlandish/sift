import Foundation

/// Reserve room for native traffic lights without transforming WebKit's root
/// coordinate system. Non-bridge pages retain their own body padding.
enum CompanionPageInset {
    static let source = """
    (function () {
      const apply = function () {
        const body = document.body;
        if (!body || body.dataset.ollieTitlebarInset) return;
        const padding = window.getComputedStyle(body).paddingTop || '0px';
        body.style.setProperty('padding-top', 'calc(' + padding + ' + \(Int(CompanionDragHitTest.insetTitleBarHeight))px)', 'important');
        body.dataset.ollieTitlebarInset = 'true';
      };
      // At document start the body and its styles may not have been parsed yet.
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', apply, { once: true });
      } else {
        apply();
      }
    })();
    """
}
