import Foundation
import WebKit

enum CompanionPath {
    static let fallback = "/companion/app"

    static func accepted(_ raw: String?) -> String {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let normalized = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let boundary = normalized.firstIndex { $0 == "?" || $0 == "#" } ?? normalized.endIndex
        let path = String(normalized[..<boundary])
        let suffix = String(normalized[boundary...])
        let decoded = path.removingPercentEncoding ?? path
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard decoded.hasPrefix("/companion/"),
              !segments.contains(where: { $0 == ".." || $0 == "." }) else { return fallback }
        return path + suffix
    }
}

enum CompanionConfig {
    static func validatedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return nil }
        return components.url
    }

    static func targetURL(base: URL, path: String?) -> URL? {
        URL(string: CompanionPath.accepted(path), relativeTo: base)?.absoluteURL
    }

    /// CLI paths may leave /companion/ (the dev sign-in lives at /e2e/auth), but
    /// they must stay on the configured scheme, host and port.
    static func cliTargetURL(base: URL, path: String?) -> URL? {
        let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.contains("://"), !raw.hasPrefix("//") else { return nil }
        let normalized = raw.isEmpty ? CompanionPath.fallback : (raw.hasPrefix("/") ? raw : "/" + raw)
        guard let target = URL(string: normalized, relativeTo: base)?.absoluteURL else { return nil }
        return originMatches(scheme: target.scheme ?? "", host: target.host ?? "",
                             port: target.port ?? 0, base: base) ? target : nil
    }

    static func originMatches(scheme: String, host: String, port: Int, base: URL) -> Bool {
        guard let baseScheme = base.scheme?.lowercased(),
              let baseHost = base.host?.lowercased() else { return false }
        let originScheme = scheme.lowercased()
        let basePort = base.port ?? (baseScheme == "https" ? 443 : 80)
        let originPort = port == 0 ? (originScheme == "https" ? 443 : 80) : port
        return originScheme == baseScheme && host.lowercased() == baseHost && originPort == basePort
    }

    static func isCompanionAppPath(_ path: String) -> Bool {
        path == "/companion/app" || path.hasPrefix("/companion/app/")
    }
}

struct CompanionBridgeShell: Equatable {
    let kind: String
    let platform: String
    let titleBar: String

    static let darwinInset = CompanionBridgeShell(kind: "desktop", platform: "darwin", titleBar: "hidden-inset")
}

enum CompanionDragHitTest {
    static let titleBarHeight: CGFloat = 52

    static func shouldDrag(button: Int, y: CGFloat, interactive: Bool) -> Bool {
        button == 0 && y >= 0 && y <= titleBarHeight && !interactive
    }

    static func shouldDoubleClick(y: CGFloat, interactive: Bool) -> Bool {
        y >= 0 && y <= titleBarHeight && !interactive
    }
}

enum CompanionBridge {
    static let shell = CompanionBridgeShell.darwinInset

    enum Call: Equatable {
        case setBadge(Int)
        case notify(String, String)
        case openExternal(URL)
        case drag
        case titlebarDoubleClick
        case unsupported
        case invalid
    }

    static func allowedPage(_ url: URL?, base: URL) -> Bool {
        guard let url,
              CompanionConfig.originMatches(scheme: url.scheme ?? "", host: url.host ?? "",
                                            port: url.port ?? 0, base: base) else { return false }
        return CompanionConfig.isCompanionAppPath(url.path)
    }

    static func validate(method: String, arguments: [Any]) -> Call {
        switch method {
        case "setBadge":
            guard arguments.count == 1, let count = integer(arguments[0]), (0...99999).contains(count) else {
                return .invalid
            }
            return .setBadge(count)
        case "notify":
            guard arguments.count == 2,
                  let title = arguments[0] as? String, (1...200).contains(title.count),
                  let body = arguments[1] as? String, (1...2000).contains(body.count) else {
                return .invalid
            }
            return .notify(title, body)
        case "openExternal":
            guard arguments.count == 1,
                  let raw = arguments[0] as? String, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
                  (1...8192).contains(raw.count),
                  let url = URL(string: raw), url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil else { return .invalid }
            return .openExternal(url)
        case "drag":
            return arguments.isEmpty ? .drag : .invalid
        case "titlebarDoubleClick":
            return arguments.isEmpty ? .titlebarDoubleClick : .invalid
        case "openSpace", "showSpace", "hideSpace", "closeSpace", "navigate":
            return .unsupported
        default:
            return .invalid
        }
    }

    private static func integer(_ value: Any) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber, value.doubleValue.rounded() == value.doubleValue {
            return value.intValue
        }
        return nil
    }
}

struct CompanionNavigationPolicy: Equatable {
    enum Decision: Equatable {
        case allow
        case external
    }

    enum WindowOpenDecision: Equatable {
        case loadInCompanion
        case openExternally
        case deny
    }

    static let defaultSignInHosts: Set<String> = [
        "outlandish.com",
        "larksuite.com",
        "larkoffice.com",
        "feishu.cn"
    ]

    let baseURL: URL
    let signInHosts: Set<String>

    init(baseURL: URL, signInHosts: Set<String> = CompanionNavigationPolicy.defaultSignInHosts) {
        self.baseURL = baseURL
        self.signInHosts = Set(signInHosts.map { $0.lowercased() })
    }

    func decision(for url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .external }
        if scheme == "about" || scheme == "blob" { return .allow }
        guard scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return .external }
        if isBaseOrigin(url) || isAuthURL(url) || isSignInHost(host) { return .allow }
        return .external
    }

    func windowOpenDecision(for url: URL, topURL: URL?) -> WindowOpenDecision {
        if let topURL, isAuthURL(topURL), !isOutlandishIdAuthURL(url), !isSignInCallback(url) {
            return .deny
        }
        if isOutlandishIdAuthURL(url) || isSignInCallback(url) { return .loadInCompanion }
        if isAuthURL(url) { return .deny }
        if isBaseOrigin(url) { return .loadInCompanion }
        if url.scheme?.lowercased() == "https", url.user == nil, url.password == nil {
            return .openExternally
        }
        return .deny
    }

    func isOutlandishIdAuthURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.port == nil, url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "api.workos.com"
            || host == "accounts.google.com"
            || host == "login.microsoftonline.com"
            || host == "login.live.com"
            || Self.isAuthKitHost(host)
    }

    func isAuthURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.port == nil, url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        if isOutlandishIdAuthURL(url) { return true }
        switch host {
        case "accounts.larksuite.com":
            return url.path.hasPrefix("/accounts/") || url.path == "/open-apis/authen/v1/authorize"
        case "open.larksuite.com":
            return url.path == "/open-apis/authen/v1/authorize"
        case "passport.larksuite.com":
            return url.path == "/accounts/page/login"
        case "login-sg.larksuite.com":
            return url.path == "/accounts/trap"
        case "accounts-sg.larksuite.com":
            return url.path == "/accounts/page/login"
        default:
            return false
        }
    }

    func isSignInCallback(_ url: URL?) -> Bool {
        guard let url, isBaseOrigin(url) else { return false }
        return url.path == "/outlandish/callback" || url.path == "/lark-oauth2/callback"
    }

    static func isAuthKitHost(_ host: String) -> Bool {
        host.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.authkit\.app$"#,
                   options: .regularExpression) != nil
    }

    private func isBaseOrigin(_ url: URL) -> Bool {
        guard let baseHost = baseURL.host?.lowercased(),
              let host = url.host?.lowercased(),
              baseHost == host,
              baseURL.scheme?.lowercased() == url.scheme?.lowercased() else { return false }
        return defaultPort(baseURL) == defaultPort(url)
    }

    private func isSignInHost(_ host: String) -> Bool {
        signInHosts.contains { allowed in
            host == allowed || host.hasSuffix("." + allowed)
        }
    }

    private func defaultPort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

enum CompanionWriteGuard {
    static let productionHosts: Set<String> = ["outlandishdigital.us", "www.outlandishdigital.us"]
    static let refusal = "Ollie Dev is read-only on production. Use your real Ollie to approve."

    static func isReadOnly(baseURL: URL?, development: Bool = AppIdentity.isDevelopment) -> Bool {
        guard development, let host = baseURL?.host?.lowercased() else { return false }
        return productionHosts.contains(host)
    }
}

extension Notification.Name {
    private static func companion(_ name: String) -> Notification.Name {
        Notification.Name(AppIdentity.notificationName(name, bundleIdentifier: AppIdentity.bundleIdentifier))
    }

    static let companionStatusRequest = Notification.Name.companion("companion-status-request")
    static let companionOpenRequest = Notification.Name.companion("companion-open-request")
    static let companionPaceRequest = Notification.Name.companion("companion-pace-request")
    static let appSettingsChanged = Notification.Name.companion("settings-changed")
}

enum CompanionSession {
    static func sessionCookieExists(for baseURL: URL, completion: @escaping (Bool) -> Void) {
        guard let host = baseURL.host?.lowercased() else {
            completion(false)
            return
        }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            completion(cookies.contains { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let matchesHost = host == domain || host.hasSuffix("." + domain)
                return matchesHost && cookie.name.lowercased().contains("session")
            })
        }
    }

}

@MainActor
final class CompanionProbeCoordinator {
    struct Result: Equatable {
        let signedIn: Bool
        let cookiePresent: Bool
        let checkedAt: Date
    }

    typealias CookieCheck = @MainActor (URL, @escaping (Bool) -> Void) -> Void
    typealias SignInCheck = @MainActor (URL, @escaping (Bool) -> Void) -> Void

    nonisolated static let cacheLifetime: TimeInterval = 30
    nonisolated static let probeTimeout: TimeInterval = 12

    private let cookieCheck: CookieCheck
    private let signInCheck: SignInCheck
    private var cached: (url: String, result: Result)?
    private var running = false
    private var waiters: [(Result) -> Void] = []

    init(cookieCheck: @escaping CookieCheck, signInCheck: @escaping SignInCheck) {
        self.cookieCheck = cookieCheck
        self.signInCheck = signInCheck
    }

    func check(baseURL: URL, completion: @escaping (Result) -> Void) {
        let key = baseURL.absoluteString
        if let cached, cached.url == key, Date().timeIntervalSince(cached.result.checkedAt) < Self.cacheLifetime {
            completion(cached.result)
            return
        }
        waiters.append(completion)
        guard !running else { return }
        running = true
        cookieCheck(baseURL) { [weak self] cookiePresent in
            guard let self else { return }
            self.signInCheck(baseURL) { signedIn in
                let result = Result(signedIn: signedIn, cookiePresent: cookiePresent, checkedAt: Date())
                self.cached = (key, result)
                self.running = false
                let waiters = self.waiters
                self.waiters = []
                waiters.forEach { $0(result) }
            }
        }
    }
}

@MainActor
final class CompanionSignInProbe: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var completion: ((Bool) -> Void)?
    private var finished = false
    private var timeout: DispatchWorkItem?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func check(baseURL: URL, timeoutAfter: TimeInterval, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        let target = CompanionConfig.targetURL(base: baseURL, path: nil) ?? baseURL
        let timeout = DispatchWorkItem { [weak self] in self?.finish(signedIn: false) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutAfter, execute: timeout)
        webView.load(URLRequest(url: target))
    }

    nonisolated static func isSignIn(_ url: URL?) -> Bool {
        guard let path = url?.path else { return true }
        return path == "/outlandish/sign-in" || path == "/login"
            || path.hasPrefix("/outlandish/sign-in/") || path.hasPrefix("/login/")
    }

    private func finish(signedIn: Bool) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        completion?(signedIn)
        completion = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        finish(signedIn: !Self.isSignIn(webView.url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(signedIn: !Self.isSignIn(webView.url))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(signedIn: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(signedIn: false)
    }
}
