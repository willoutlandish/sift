import AppKit
import WebKit
import os.log
import Combine

final class CompanionWebView: WKWebView {
    private static let dragLog = OSLog(subsystem: "com.outlandish.ollie", category: "drag")
    var isCompanionPage: () -> Bool = { false }
    var dragMap: () -> CompanionDragMap = { CompanionDragMap() }
    var refreshDragMap: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    func dragDecision(at point: CGPoint, now: Date = Date()) ->
        (drag: Bool, top: CGFloat, strip: CGFloat, companion: Bool, rows: Int, interactive: Bool) {
        let map = dragMap()
        // The asynchronous refresh must not delay this press or replace its snapshot.
        if map.needsRefresh(now: now) { refreshDragMap() }
        let companion = isCompanionPage()
        let scale = map.scale(for: bounds)
        let interactive = CompanionDragHitTest.isInteractive(point: point, in: bounds, rows: map.rows,
                                                              isFlipped: isFlipped, scale: scale)
        let drag = CompanionDragHitTest.shouldDrag(point: point, in: bounds, strip: map.stripHeight,
            rows: map.rows, isCompanionPage: companion, isFlipped: isFlipped, scale: scale)
        return (drag, CompanionDragHitTest.yFromTop(point, in: bounds, isFlipped: isFlipped),
                map.stripHeight * scale, companion, map.rows.count, interactive)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event, event.buttonNumber == 0 else { return false }
        return dragDecision(at: convert(event.locationInWindow, from: nil)).drag
    }

    override func mouseDown(with event: NSEvent) {
        let decision = dragDecision(at: convert(event.locationInWindow, from: nil))
        let drag = event.buttonNumber == 0 && decision.drag
        if decision.top >= 0 && decision.top <= 160 {
            // Geometry and booleans only; drag=1, pass=0. No page URLs or content.
            os_log("y=%{public}.2f strip=%{public}.2f companion=%{public}d key=%{public}d rows=%{public}d interactive=%{public}d drag=%{public}d flipped=%{public}d",
                   log: Self.dragLog, type: .default, Double(decision.top), Double(decision.strip),
                   decision.companion ? 1 : 0, window?.isKeyWindow == true ? 1 : 0, decision.rows,
                   decision.interactive ? 1 : 0, drag ? 1 : 0, isFlipped ? 1 : 0)
        }
        guard drag else {
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
    private var titlebarMap = CompanionDragMap()
    private var titlePath = ""
    private var titleSubscription: AnyCancellable?
    private var externalOpenTimes: [Date] = []

    private init() {
        let configuration = CompanionWebConfiguration.make()
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
        contentController.add(self, contentWorld: .page, name: "ollieUpdateGuard")
        contentController.add(self, contentWorld: .page, name: "ollieTitlebar")
        contentController.add(self, contentWorld: .page, name: "ollieRoute")
        titleSubscription = CompanionApprovalsMonitor.shared.$shopNames.sink { [weak self] names in
            guard let self else { return }
            self.window?.title = CompanionWindowTitle.make(path: self.titlePath, names: names)
        }
        webView.isCompanionPage = { [weak self] in self?.companionPageActive ?? false }
        webView.dragMap = { [weak self] in self?.titlebarMap ?? CompanionDragMap() }
        webView.refreshDragMap = { [weak self] in self?.requestTitlebarMap() }
        webView.onDoubleClick = { [weak self] in self?.performTitlebarDoubleClick() }
        positionTrafficLights()
        windowObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestTitlebarMap() }
            },
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

    private func requestTitlebarMap() {
        webView.evaluateJavaScript("window.__ollieTitlebarRefresh?.()", completionHandler: nil)
    }

    func dragMapPayload() async -> [String: Any] {
        if let payload = try? await webView.evaluateJavaScript("window.__ollieTitlebarMap?.()") as? [String: Any] {
            titlebarMap.update(payload, now: Date())
        }
        let rows = titlebarMap.rows.map { row in
            ["start": Double(row.start), "end": Double(row.end),
             "intervals": row.intervals.map { [Double($0.lowerBound), Double($0.upperBound)] }]
        }
        return ["ok": true, "rows": rows, "strip_height": Double(titlebarMap.stripHeight),
                "header_bottom": Double(titlebarMap.headerBottom), "rail_inset_bottom": Double(titlebarMap.railInsetBottom),
                "viewport_width": Double(titlebarMap.viewportWidth), "view_width": Double(webView.bounds.width),
                "view_height": Double(webView.bounds.height), "is_flipped": webView.isFlipped,
                "is_companion_page": companionPageActive, "window_is_key": window?.isKeyWindow == true,
                "map_age_seconds": titlebarMap.updatedAt.map { max(0, Date().timeIntervalSince($0)) } ?? -1]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentURL: URL? { webView.url }

    func open(baseURL: URL, path: String?, allowAnyPath: Bool = false, source: CompanionOpenSource = .panel, restoringURL: URL? = nil) {
        if source == .dock, self.baseURL == baseURL, webView.url != nil {
            reveal(source: source)
            return
        }
        let target = CompanionRestore.url(restoringURL?.absoluteString, base: baseURL) ?? (allowAnyPath ? CompanionConfig.cliTargetURL(base: baseURL, path: path) : nil)
            ?? CompanionConfig.targetURL(base: baseURL, path: path)
            ?? baseURL
        self.baseURL = baseURL
        policy = CompanionNavigationPolicy(baseURL: baseURL)
        installCompanionBridge(appOrigin: baseURL)
        reveal(source: source)
        webView.load(URLRequest(url: target))
    }

    private func reveal(source: CompanionOpenSource) {
        if let window {
            // canJoinAllSpaces and moveToActiveSpace are mutually exclusive.
            // Clear prior foreground behavior so a later scheme open stays passive.
            window.collectionBehavior.subtract([.canJoinAllSpaces, .moveToActiveSpace, .fullScreenAuxiliary])
            window.collectionBehavior.formUnion(source.collectionBehavior)
        }
        if source.requestsForeground {
            if window?.isMiniaturized == true { window?.deminiaturize(nil) }
            // Recover saved frames from disconnected displays before showing the window.
            if let window, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
                window.center()
            }
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFront(nil)
        }
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
        let titlebarSource = CompanionTitlebarScript.source(escapedOrigin: escaped)
        userContentController.removeAllUserScripts()
        userContentController.addUserScript(WKUserScript(source: CompanionUpdateGuard.source,
                                                         injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        requestTitlebarMap()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        if message.name == "ollieRoute" {
            guard let baseURL,
                  CompanionConfig.originMatches(scheme: message.frameInfo.securityOrigin.`protocol`,
                      host: message.frameInfo.securityOrigin.host,
                      port: message.frameInfo.securityOrigin.port, base: baseURL),
                  let path = message.body as? String else { return }
            titlePath = path
            window?.title = CompanionWindowTitle.make(path: path, names: CompanionApprovalsMonitor.shared.shopNames)
            return
        }
        if message.name == "ollieUpdateGuard" {
            guard let baseURL,
                  CompanionConfig.originMatches(scheme: message.frameInfo.securityOrigin.`protocol`,
                                                host: message.frameInfo.securityOrigin.host,
                                                port: message.frameInfo.securityOrigin.port, base: baseURL),
                  let busy = message.body as? Bool else { return }
            OllieUpdates.shared.companionBusy = busy
            return
        }
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
              let payload = message.body as? [String: Any] else { return }
        titlebarMap.update(payload, now: Date())
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
        titlePath = companionPageActive ? (webView.url?.path ?? "") : ""
        window?.title = CompanionWindowTitle.make(path: titlePath, names: CompanionApprovalsMonitor.shared.shopNames)
        titlebarMap = CompanionDragMap()
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
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(CompanionNavigationPolicy.subframeDecision(for: url))
            return
        }
        switch policy?.decision(for: url) ?? .allow {
        case .allow:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .external:
            if let safe = CompanionNavigationPolicy.externalLinkURL(
                url, isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                navigationType: navigationAction.navigationType) {
                NSWorkspace.shared.open(safe)
            }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(CompanionNavigationPolicy.responseDecision(
            response: navigationResponse.response, canShowMIMEType: navigationResponse.canShowMIMEType,
            isMainFrame: navigationResponse.isForMainFrame, baseURL: baseURL))
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
