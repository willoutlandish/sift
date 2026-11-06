import AppKit
import WebKit

@MainActor
final class CompanionWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandlerWithReply {
    static let shared = CompanionWindowController()

    private let webView: WKWebView
    private var policy: CompanionNavigationPolicy?
    private var baseURL: URL?

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = WKUserContentController()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ollie"
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OllieCompanionWindow")
        window.center()

        self.webView = webView
        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.userContentController.addScriptMessageHandler(
            self, contentWorld: .page, name: "ollie")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(baseURL: URL, path: String?, allowAnyPath: Bool = false) {
        let target = (allowAnyPath ? CompanionConfig.cliTargetURL(base: baseURL, path: path) : nil)
            ?? CompanionConfig.targetURL(base: baseURL, path: path)
            ?? baseURL
        self.baseURL = baseURL
        policy = CompanionNavigationPolicy(baseURL: baseURL)
        installCompanionBridge(appOrigin: baseURL)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
              kind: 'desktop',
              platform: 'darwin',
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
        })();
        """
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              let baseURL,
              CompanionBridge.allowedPage(message.webView?.url ?? message.frameInfo.request.url, base: baseURL),
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
        switch CompanionBridge.validate(method: method, arguments: arguments) {
        case .setBadge(let count):
            OllieBadge.setUnread(count)
            replyHandler(true, nil)
        case .notify(let title, let body):
            Task { await Notifications.shared.postBridge(title: title, body: body) }
            replyHandler(true, nil)
        case .openExternal(let url):
            NSWorkspace.shared.open(url)
            replyHandler(true, nil)
        case .unsupported:
            replyHandler(nil, "Unsupported Companion method")
        case .invalid:
            replyHandler(nil, "Invalid Companion bridge arguments")
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
