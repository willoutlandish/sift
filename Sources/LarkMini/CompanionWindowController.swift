import AppKit
import WebKit

@MainActor
final class CompanionWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    static let shared = CompanionWindowController()

    private let webView: WKWebView
    private let userContentController: WKUserContentController
    private var policy: CompanionNavigationPolicy?
    private var baseURL: URL?
    private var windowObservers: [NSObjectProtocol] = []
    private var lastTitlebarDoubleClick = Date.distantPast
    private var passkeyHintShown = false

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
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

    private func performWindowDrag() {
        guard let window else { return }
        let location = window.mouseLocationOutsideOfEventStream
        let event = NSApp.currentEvent?.type == .leftMouseDown ? NSApp.currentEvent : NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)
        guard let event else { return }
        window.performDrag(with: event)
    }

    private func performTitlebarDoubleClick() {
        guard let window else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTitlebarDoubleClick) > 0.35 else { return }
        lastTitlebarDoubleClick = now
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize":
            window.miniaturize(nil)
        case "None":
            break
        default:
            window.zoom(nil)
        }
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
        let dragSource = """
        (function () {
          const appOrigin = "\(escaped)";
          if (window.top !== window || location.origin !== appOrigin) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ollie;
          if (!handler) return;
          const interactive = "button, a, input, select, textarea, [role='menu'], [role='menuitem'], [role='dialog'], [contenteditable]";
          const isInteractive = (target) => !!(target && target.closest && target.closest(interactive));
          const inTitleBar = (event) => event.clientY >= 0 && event.clientY <= 52;
          document.addEventListener('mousedown', function (event) {
            if (event.button !== 0 || !inTitleBar(event) || isInteractive(event.target)) return;
            if (event.detail === 2) handler.postMessage({ method: 'titlebarDoubleClick', args: [] });
            else handler.postMessage({ method: 'drag', args: [] });
            event.preventDefault();
            event.stopPropagation();
          }, true);
          document.addEventListener('dblclick', function (event) {
            if (!inTitleBar(event) || isInteractive(event.target)) return;
            handler.postMessage({ method: 'titlebarDoubleClick', args: [] });
            event.preventDefault();
            event.stopPropagation();
          }, true);
          if (location.pathname !== '/companion/app' && !location.pathname.startsWith('/companion/app/')) {
            const apply = function () {
              if (!document.documentElement) return;
              document.documentElement.style.setProperty('transform', 'translateY(28px)', 'important');
              document.documentElement.style.setProperty('height', 'calc(100% - 28px)', 'important');
            };
            apply();
            if (!document.documentElement) document.addEventListener('DOMContentLoaded', apply, { once: true });
          }
        })();
        """
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: true))
        userContentController.addUserScript(WKUserScript(source: dragSource, injectionTime: .atDocumentStart,
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
        guard message.name == "ollieAuthHint", message.frameInfo.isMainFrame else { return }
        showPasskeyHint()
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
        case .drag:
            performWindowDrag()
            replyHandler(true, nil)
        case .titlebarDoubleClick:
            performTitlebarDoubleClick()
            replyHandler(true, nil)
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
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch policy?.decision(for: url) ?? .allow {
        case .allow:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .external:
            if isMainFrame {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
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
        switch type {
        case .camera, .microphone, .cameraAndMicrophone:
            decisionHandler(.grant)
        @unknown default:
            decisionHandler(.prompt)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let filename = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var destination = directory.appendingPathComponent(filename)
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
}
