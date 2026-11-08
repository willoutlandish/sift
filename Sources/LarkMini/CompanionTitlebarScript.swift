import Foundation

/// The existing DOM drag map, shared with in-process script tests.
enum CompanionTitlebarScript {
    static func source(escapedOrigin: String) -> String {
        """
        (function () {
          const appOrigin = "\(escapedOrigin)";
          if (window.top !== window) return;
          const isCompanion = () => location.origin === appOrigin &&
            (location.pathname === '/companion/app' || location.pathname.startsWith('/companion/app/'));

          const handler = window.webkit && window.webkit.messageHandlers &&
            window.webkit.messageHandlers.ollieTitlebar;
          const controlTags = new Set(['button', 'input', 'select', 'textarea', 'summary']);
          const controlRoles = new Set([
            'button', 'link', 'menuitem', 'tab', 'switch', 'checkbox', 'combobox', 'option'
          ]);
          const isControl = function (element) {
            let node = element;
            while (node && node !== document.body && node !== document.documentElement) {
              const tag = (node.tagName || '').toLowerCase();
              const role = ((node.getAttribute && node.getAttribute('role')) || '').toLowerCase();
              if (controlTags.has(tag)) return true;
              if (tag === 'a' && node.hasAttribute('href')) return true;
              if (tag === 'label' && node.hasAttribute('for')) return true;
              if (controlRoles.has(role)) return true;
              if (node.getAttribute && node.getAttribute('contenteditable') === 'true') return true;
              if (window.getComputedStyle(node).cursor === 'pointer') return true;
              node = node.parentElement;
            }
            return false;
          };
          const number = value => Number.parseFloat(value) || 0;
          const geometry = function () {
            let headerBottom = 0, railInsetBottom = 0;
            if (isCompanion()) {
              for (const header of document.querySelectorAll('.c1-shell-header')) {
                const rect = header.getBoundingClientRect();
                if (rect.width > 0 && rect.height > 0) headerBottom = Math.max(headerBottom, rect.bottom);
              }
              const rail = document.querySelector('.c1-desktop-inset > nav:first-child') ||
                document.querySelector('.c1-desktop-inset .c1-rail');
              if (rail) {
                const rect = rail.getBoundingClientRect();
                if (rect.width > 0 && rect.height > 0) {
                  const style = window.getComputedStyle(rail);
                  const before = window.getComputedStyle(rail, '::before');
                  railInsetBottom = rect.top + number(style.paddingTop);
                  if (before.content && before.content !== 'none' && before.content !== 'normal' && before.display !== 'none') {
                    const top = before.position === 'absolute' ? rect.top + number(before.top) : railInsetBottom;
                    railInsetBottom = Math.max(railInsetBottom, top + number(before.marginTop) +
                      number(before.height) + number(before.marginBottom));
                  }
                }
              }
            }
            return {headerBottom, railInsetBottom,
              stripHeight: isCompanion() ? Math.min(140, Math.max(52, headerBottom, railInsetBottom)) : 28};
          };
          const build = function () {
            const measured = geometry();
            const strip = measured.stripHeight;
            const width = Math.max(1, window.innerWidth);
            const count = Math.ceil(strip / 4);
            const band = strip / count;
            const rows = [];
            for (let index = 0; index < count; index++) {
              const start = index * band;
              const end = (index + 1) * band;
              const y = (start + end) / 2;
              const intervals = [];
              let current = null;
              for (let x = 0; x < width; x += 4) {
                const element = document.elementFromPoint(x, y);
                const hit = element ? isControl(element) : false;
                if (hit) {
                  if (!current) current = [x, Math.min(width, x + 4)];
                  else current[1] = Math.min(width, x + 4);
                } else if (current) {
                  intervals.push(current);
                  current = null;
                }
              }
              if (current) intervals.push(current);
              rows.push({ start: start, end: end, intervals: intervals });
            }
            return {...measured, viewportWidth: width, rows};
          };
          window.__ollieTitlebarMap = build;
          const post = function () { if (handler) handler.postMessage(build()); };
          let scheduled = false;
          const schedule = function () {
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(function () { scheduled = false; post(); });
          };
          window.__ollieTitlebarRefresh = schedule;
          for (const name of ['pushState', 'replaceState']) {
            const original = history[name];
            history[name] = function (...args) {
              const result = original.apply(this, args);
              schedule();
              return result;
            };
          }
          window.addEventListener('popstate', schedule);
          window.addEventListener('hashchange', schedule);
          window.addEventListener('load', schedule);
          window.addEventListener('resize', schedule);
          document.addEventListener('scroll', schedule, true);
          new MutationObserver(schedule).observe(document,
            { childList: true, subtree: true, attributes: true,
              attributeFilter: ['style', 'class', 'hidden', 'aria-hidden', 'href', 'role'] });
          if (window.ResizeObserver && document.documentElement) {
            new ResizeObserver(schedule).observe(document.documentElement);
          }
          document.addEventListener('DOMContentLoaded', schedule);
          if (!isCompanion()) {
            \(CompanionPageInset.source)
          }
          schedule();
        })();
        """
    }
}
