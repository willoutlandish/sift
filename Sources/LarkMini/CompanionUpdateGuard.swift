import Foundation

// Observes the existing Companion inline Change form and chat composer, without
// rebuilding either. Only a busy boolean leaves the page, never draft contents.
enum CompanionUpdateGuard {
    static let source = """
    (() => {
      let pending = 0, previous;
      const edited = new Map();
      const field = node => node?.closest?.('input, textarea, [contenteditable]:not([contenteditable="false"])');
      const value = node => node.isContentEditable ? node.textContent : node.value;
      const reset = scope => {
        for (const node of edited.keys()) if (scope === node || scope?.contains(node)) edited.delete(node);
      };
      const send = () => {
        const dialog = [...document.querySelectorAll('[role="dialog"], [role="alertdialog"], dialog[open]')]
          .some(el => el.getClientRects().length > 0);
        for (const [node, lastEdit] of edited) {
          // Unmounted editors were closed; a controlled field cleared by React
          // after sending/resetting is no longer a draft. User edits stay dirty.
          if (!node.isConnected || (value(node) === '' && lastEdit !== '')) edited.delete(node);
        }
        const busy = pending > 0 || dialog || (document.hasFocus() && !!field(document.activeElement)) || edited.size > 0;
        if (busy !== previous) {
          previous = busy;
          window.webkit.messageHandlers.ollieUpdateGuard.postMessage(busy);
        }
      };
      const writes = method => !['GET', 'HEAD', 'OPTIONS'].includes(String(method || 'GET').toUpperCase());
      const fetchOriginal = window.fetch;
      window.fetch = async function(input, init) {
        const write = writes(init?.method || input?.method);
        if (write) { pending++; send(); }
        try { return await fetchOriginal.apply(this, arguments); }
        finally { if (write) { pending--; send(); } }
      };
      const open = XMLHttpRequest.prototype.open, transmit = XMLHttpRequest.prototype.send;
      const mutating = new WeakSet();
      XMLHttpRequest.prototype.open = function(method) {
        if (writes(method)) mutating.add(this); else mutating.delete(this);
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        const write = mutating.has(this);
        let ended = false;
        const end = () => { if (!ended && write) { ended = true; pending--; send(); } };
        if (write) { pending++; send(); this.addEventListener('loadend', end, {once: true}); }
        try { return transmit.apply(this, arguments); } catch (error) { end(); throw error; }
      };
      for (const event of ['input', 'change']) document.addEventListener(event, e => {
        const node = field(e.target);
        if (node) edited.set(node, value(node));
        send();
      }, true);
      window.addEventListener('focus', send);
      window.addEventListener('blur', () => queueMicrotask(send));
      document.addEventListener('focusin', send, true);
      document.addEventListener('focusout', () => queueMicrotask(send), true);
      // Run after React's handler. Rejected submits retain their draft; successful
      // handlers either unmount the editor or clear it, also handled by send().
      document.addEventListener('submit', e => queueMicrotask(() => {
        if (!e.defaultPrevented) reset(e.target);
        send();
      }), true);
      document.addEventListener('reset', e => queueMicrotask(() => {
        if (!e.defaultPrevented) reset(e.target);
        send();
      }), true);
      document.addEventListener('DOMContentLoaded', () => {
        new MutationObserver(send).observe(document.documentElement,
          {childList: true, subtree: true, attributes: true});
        send();
        setInterval(send, 1000);
      }, {once: true});
    })();
    """
}
