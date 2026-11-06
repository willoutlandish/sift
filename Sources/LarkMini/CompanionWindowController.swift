import AppKit
import WebKit

final class CompanionWebView: WKWebView {
    var isCompanionPage: () -> Bool = { false }
    var interactiveRows: () -> [CompanionDragRow] = { [] }
    var onDoubleClick: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let strip = isCompanionPage() ? CompanionDragHitTest.titleBarHeight
                                      : CompanionDragHitTest.insetTitleBarHeight
        guard CompanionDragHitTest.shouldDrag(point: point, in: bounds, strip: strip,
                                               rows: interactiveRows()) else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            onDoubleClick()
            return
        }
        window?.performDrag(with: event)
    }
}

@MainActor
final class CompanionWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    static let shared = CompanionWindowController()

    private let webView: CompanionWebView
    private let userContentController: WKUserContentController
    private var policy: CompanionNavigationPolicy?
    private var baseURL: URL?
    private var windowObservers: [NSObjectProtocol] = []
    private var lastTitlebarDoubleClick = Date.distantPast
    private var passkeyHintShown = false
    private var titlebarRows: [CompanionDragRow] = []
    private var externalOpenTimes: [Date] = []

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        let webView = CompanionWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.displayName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OllieCompanionWindow")
        window.center()

        self.webView = webView
        self.userContentController = contentController
        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        contentController.addScriptMessageHandler(self, contentWorld: .page, name: "ollie")
        contentController.add(self, contentWorld: .page, name: "ollieAuthHint")
        contentController.add(self, contentWorld: .page, name: "ollieTitlebar")
        webView.isCompanionPage = { [weak self] in self?.companionPageActive ?? false }
        webView.interactiveRows = { [weak self] in self?.titlebarRows ?? [] }
        webView.onDoubleClick = { [weak self] in self?.performTitlebarDoubleClick() }
        positionTrafficLights()
        windowObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionTrafficLights() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.async { self?.positionTrafficLights() }
                }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.async { self?.positionTrafficLights() }
                }
            }
        ]
    }

    private static let passkeyHintSource = """
    (function () {
      if (window.__olliePasskeyHint) return;
      window.__olliePasskeyHint = true;
      const send = function () {
        try { window.webkit.messageHandlers.ollieAuthHint.postMessage("hint"); } catch (error) {}
      };
      const looksLikePasskey = function (value) {
        return /passkey|security key/i.test((value || "").toLowerCase());
      };
      document.addEventListener("click", function (event) {
        const target = event.target && event.target.closest
          ? event.target.closest('button, a, [role="button"], input[type="button"], input[type="submit"]')
          : null;
        if (!target) return;
        if (looksLikePasskey(target.innerText) || looksLikePasskey(target.value) ||
            looksLikePasskey(target.getAttribute("aria-label"))) send();
      }, true);
      const wrap = function (name) {
        const credentials = navigator.credentials;
        if (!credentials || typeof credentials[name] !== "function") return;
        const original = credentials[name].bind(credentials);
        credentials[name] = function () {
          return original.apply(null, arguments).catch(function (error) {
            if (error && /NotAllowed|Security|NotSupported/i.test(error.name || "")) send();
            throw error;
          });
        };
      };
      wrap("create");
      wrap("get");
    })();
    """

    private func positionTrafficLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = close.superview else { return }
        let size = close.frame.size
        let y = titlebar.bounds.height - 18 - size.height
        let gap: CGFloat = 6
        close.setFrameOrigin(NSPoint(x: 20, y: y))
        mini.setFrameOrigin(NSPoint(x: 20 + size.width + gap, y: y))
        zoom.setFrameOrigin(NSPoint(x: 20 + 2 * (size.width + gap), y: y))
        updateLightsInset()
    }

    private var companionPageActive: Bool {
        guard let baseURL, let url = webView.url else { return false }
        return CompanionConfig.originMatches(scheme: url.scheme ?? "", host: url.host ?? "",
                                             port: url.port ?? 0, base: baseURL)
            && CompanionConfig.isCompanionAppPath(url.path)
    }

    private func lightsRightEdge() -> CGFloat? {
        guard let window, let zoom = window.standardWindowButton(.zoomButton), let content = window.contentView else {
            return nil
        }
        return content.convert(zoom.bounds, from: zoom).maxX
    }

    private func updateLightsInset() {
        guard let right = lightsRightEdge() else { return }
        let script = "document.documentElement.style.setProperty('--ollie-lights-right', '\(String(format: "%.2f", right))px');"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func performTitlebarDoubleClick() {
        guard let window else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTitlebarDoubleClick) > 0.35 else { return }
        lastTitlebarDoubleClick = now
        switch CompanionDragHitTest.doubleClickAction(
            UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
        case .minimize: window.miniaturize(nil)
        case .zoom: window.zoom(nil)
        case .none: break
        }
    }

    func dragMapPayload() async -> [String: Any] {
        let rows = titlebarRows.map { row in
            ["start": Double(row.start), "end": Double(row.end),
             "intervals": row.intervals.map { [Double($0.lowerBound), Double($0.upperBound)] }]
        }
        return ["ok": true, "url": webView.url?.absoluteString ?? "", "rows": rows]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(baseURL: URL, path: String?, allowAnyPath: Bool = false, activate: Bool = true) {
        let target = (allowAnyPath ? CompanionConfig.cliTargetURL(base: baseURL, path: path) : nil)
            ?? CompanionConfig.targetURL(base: baseURL, path: path)
            ?? baseURL
        self.baseURL = baseURL
        policy = CompanionNavigationPolicy(baseURL: baseURL)
        installCompanionBridge(appOrigin: baseURL)
        if activate {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFront(nil)
        }
        webView.load(URLRequest(url: target))
    }

    private func installCompanionBridge(appOrigin: URL) {
        var components = URLComponents()
        components.scheme = appOrigin.scheme
        components.host = appOrigin.host
        components.port = appOrigin.port
        let origin = components.string ?? appOrigin.absoluteString
        let escaped = origin
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let lightsRight = lightsRightEdge().map { String(format: "%.2f", $0) }
        let source = """
        (function () {
          const appOrigin = "\(escaped)";
          if (window.top !== window || location.origin !== appOrigin) return;
          if (location.pathname !== '/companion/app' && !location.pathname.startsWith('/companion/app/')) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ollie;
          if (!handler) return;
          const call = (method) => (...args) => handler.postMessage({ method, args });
          window.companion = Object.freeze({
            shell: Object.freeze({
              kind: "\(CompanionBridge.shell.kind)",
              platform: "\(CompanionBridge.shell.platform)",
              titleBar: "\(CompanionBridge.shell.titleBar)",
              openExternal: call('openExternal')
            }),
            setBadge: call('setBadge'),
            notify: call('notify'),
            openExternal: call('openExternal'),
            openSpace: call('openSpace'),
            showSpace: call('showSpace'),
            hideSpace: call('hideSpace'),
            closeSpace: call('closeSpace'),
            navigate: call('navigate')
          });
          const lightsRight = "\(lightsRight ?? "")";
          const ensureInset = function () {
            if (document.documentElement && lightsRight) {
              document.documentElement.style.setProperty('--ollie-lights-right', lightsRight + 'px');
            }
            const root = document.querySelector('.c1-v4');
            if (root && !root.classList.contains('c1-desktop-inset')) {
              root.classList.add('c1-desktop-inset');
            }
            let style = document.getElementById('ollie-desktop-inset');
            if (!style) {
              style = document.createElement('style');
              style.id = 'ollie-desktop-inset';
              style.textContent = [
                '.c1-rail { padding-top: 52px !important; }',
                '@media (min-width: 751px) {',
                '  .c1-desktop-inset .c1-rail { width: calc(var(--ollie-lights-right) + 12px) !important; align-items: center !important; }',
                '  .c1-desktop-inset .c1-rail .c1-rail-pages,',
                '  .c1-desktop-inset .c1-rail .c1-rail-low { align-items: center !important; }',
                '}'
              ].join(' ');
              (document.head || document.documentElement).appendChild(style);
            }
          };
          ensureInset();
          new MutationObserver(ensureInset).observe(document.documentElement,
            { childList: true, subtree: true });
        })();
        """
        let titlebarSource = """
        (function () {
          const appOrigin = "\(escaped)";
          if (window.top !== window) return;
          const isCompanion = location.origin === appOrigin &&
            (location.pathname === '/companion/app' || location.pathname.startsWith('/companion/app/'));
          const strip = isCompanion ? 52 : 28;
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
          const build = function () {
            const width = Math.max(1, window.innerWidth);
            const count = strip >= 52 ? 3 : 2;
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
            return rows;
          };
          window.__ollieTitlebarMap = build;
          const post = function () { if (handler) handler.postMessage(build()); };
          let scheduled = false;
          const schedule = function () {
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(function () { scheduled = false; post(); });
          };
          window.addEventListener('resize', schedule);
          document.addEventListener('scroll', schedule, true);
          new MutationObserver(schedule).observe(document.documentElement,
            { childList: true, subtree: true, attributes: true,
              attributeFilter: ['style', 'class', 'hidden', 'aria-hidden', 'href', 'role'] });
          if (window.ResizeObserver) new ResizeObserver(schedule).observe(document.documentElement);
          document.addEventListener('DOMContentLoaded', schedule);
          if (!isCompanion) {
            const apply = function () {
              if (!document.documentElement) return;
              document.documentElement.style.setProperty('transform', 'translateY(28px)', 'important');
              document.documentElement.style.setProperty('height', 'calc(100% - 28px)', 'important');
            };
            apply();
            if (!document.documentElement) document.addEventListener('DOMContentLoaded', apply, { once: true });
          }
          schedule();
        })();
        """
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: true))
        userContentController.addUserScript(WKUserScript(source: titlebarSource, injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: true))
        userContentController.addUserScript(WKUserScript(source: Self.passkeyHintSource,
                                                         injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: false))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateLightsInset()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        if message.name == "ollieAuthHint" {
            showPasskeyHint()
            return
        }
        guard message.name == "ollieTitlebar",
              let baseURL,
              CompanionConfig.originMatches(scheme: message.frameInfo.securityOrigin.`protocol`,
                                            host: message.frameInfo.securityOrigin.host,
                                            port: message.frameInfo.securityOrigin.port,
                                            base: baseURL),
              let rows = message.body as? [[String: Any]] else { return }
        titlebarRows = CompanionDragHitTest.rows(from: rows)
    }

    private func showPasskeyHint() {
        guard !passkeyHintShown else { return }
        passkeyHintShown = true
        let alert = NSAlert()
        alert.messageText = "Passkeys don't work inside Ollie yet: choose email code or Google."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        passkeyHintShown = false
        titlebarRows = []
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              let baseURL,
              CompanionConfig.originMatches(
                scheme: message.frameInfo.securityOrigin.`protocol`,
                host: message.frameInfo.securityOrigin.host,
                port: message.frameInfo.securityOrigin.port,
                base: baseURL),
              let body = message.body as? [String: Any],
              let method = body["method"] as? String,
              let arguments = body["args"] as? [Any] else {
            replyHandler(nil, "Invalid Companion bridge call")
            return
        }
        let call = CompanionBridge.validate(method: method, arguments: arguments)
        switch call {
        case .unsupported:
            replyHandler(nil, "Unsupported Companion method")
        case .invalid:
            replyHandler(nil, "Invalid Companion bridge arguments")
        case .setBadge, .notify, .openExternal:
            guard CompanionBridge.allowedPage(message.webView?.url ?? message.frameInfo.request.url, base: baseURL) else {
                replyHandler(nil, "Invalid Companion bridge call")
                return
            }
            switch call {
            case .setBadge(let count):
                OllieBadge.setUnread(count)
                replyHandler(true, nil)
            case .notify(let title, let body):
                Task { await Notifications.shared.postBridge(title: title, body: body) }
                replyHandler(true, nil)
            case .openExternal(let url):
                let now = Date()
                externalOpenTimes = externalOpenTimes.filter { now.timeIntervalSince($0) < 10 }
                guard externalOpenTimes.count < 3 else {
                    replyHandler(nil, "Too many external opens")
                    return
                }
                externalOpenTimes.append(now)
                NSWorkspace.shared.open(url)
                replyHandler(true, nil)
            default:
                replyHandler(nil, "Invalid Companion bridge call")
            }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.targetFrame == nil {
            switch policy?.windowOpenDecision(for: url, topURL: webView.url) ?? .deny {
            case .loadInCompanion:
                decisionHandler(.allow)
            case .openExternally:
                if navigationAction.navigationType == .linkActivated,
                   let safe = CompanionNavigationPolicy.externalURL(url) {
                    NSWorkspace.shared.open(safe)
                }
                decisionHandler(.cancel)
            case .deny:
                decisionHandler(.cancel)
            }
            return
        }
        switch policy?.decision(for: url) ?? .allow {
        case .allow:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .external:
            if navigationAction.navigationType == .linkActivated,
               navigationAction.targetFrame?.isMainFrame == true,
               let safe = CompanionNavigationPolicy.externalURL(url) {
                NSWorkspace.shared.open(safe)
            }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame,
              let baseURL,
              let url = navigationResponse.response.url,
              CompanionConfig.originMatches(scheme: url.scheme ?? "", host: url.host ?? "",
                                            port: url.port ?? 0, base: baseURL) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        switch policy?.windowOpenDecision(for: url, topURL: webView.url) ?? .deny {
        case .loadInCompanion:
            webView.load(URLRequest(url: url))
        case .openExternally:
            NSWorkspace.shared.open(url)
        case .deny:
            break
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard frame.isMainFrame,
              let baseURL,
              CompanionConfig.originMatches(scheme: origin.`protocol`, host: origin.host,
                                            port: origin.port, base: baseURL) else {
            decisionHandler(.prompt)
            return
        }
        decisionHandler(.prompt)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard navigationAction.targetFrame?.isMainFrame == true,
              let baseURL, let url = navigationAction.request.url,
              CompanionConfig.originMatches(scheme: url.scheme ?? "", host: url.host ?? "",
                                            port: url.port ?? 0, base: baseURL) else {
            download.cancel()
            return
        }
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard navigationResponse.isForMainFrame,
              let baseURL, let url = navigationResponse.response.url,
              CompanionConfig.originMatches(scheme: url.scheme ?? "", host: url.host ?? "",
                                            port: url.port ?? 0, base: baseURL) else {
            download.cancel()
            return
        }
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let safe = Self.safeDownloadName(suggestedFilename)
        guard !safe.isEmpty else { completionHandler(nil); return }
        var destination = directory.appendingPathComponent(safe)
        let stem = destination.deletingPathExtension().lastPathComponent
        let suffix = destination.pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = "\(stem) \(index)" + (suffix.isEmpty ? "" : ".\(suffix)")
            destination = directory.appendingPathComponent(name)
            index += 1
        }
        completionHandler(destination)
    }

    nonisolated static func safeDownloadName(_ suggested: String) -> String {
        let base = URL(fileURLWithPath: suggested).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let blocked: Set<String> = ["command", "terminal", "app", "pkg", "dmg", "sh", "tool", "scpt"]
        let ext = (base as NSString).pathExtension.lowercased()
        guard !base.isEmpty, !blocked.contains(ext) else { return "" }
        return base
    }
}
