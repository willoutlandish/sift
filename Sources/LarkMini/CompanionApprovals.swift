import Foundation
import WebKit

struct CompanionApprovalsList: Decodable {
    struct Counts: Decodable {
        let pending: Int
        let mine: Int?
    }

    struct Shop: Decodable {
        let resource: String
        let name: String
        let services: [Service]
    }

    struct Service: Decodable {
        let role: String?
        let label: String
        let items: [Item]
    }

    struct Item: Decodable {
        struct Agent: Decodable { let label: String? }
        struct ShopRef: Decodable { let resource: String?; let name: String? }

        let id: String
        let source: String?
        let kind: String?
        let question: String?
        let agent: Agent?
        let shop: ShopRef?
    }

    let shops: [Shop]
    let counts: Counts?
}

struct CompanionApproval: Equatable {
    let id: String
    let label: String
    let question: String
    let resource: String?
    let shopName: String?

    var clickPath: String {
        CompanionApprovals.clickPath(resource: resource)
    }
}

enum CompanionApprovals {
    static func flatten(_ list: CompanionApprovalsList) -> [CompanionApproval] {
        list.shops.flatMap { shop in
            shop.services.flatMap { service in
                service.items.compactMap { item in
                    guard !item.id.isEmpty else { return nil }
                    let resource = nonEmpty(item.shop?.resource) ?? nonEmpty(shop.resource)
                    let shopName = nonEmpty(item.shop?.name) ?? nonEmpty(shop.name)
                    let label = nonEmpty(item.agent?.label) ?? nonEmpty(service.label) ?? "An agent"
                    let question = nonEmpty(item.question) ?? nonEmpty(item.kind) ?? nonEmpty(item.source) ?? "Approval"
                    return CompanionApproval(id: item.id, label: label, question: question,
                                             resource: resource, shopName: shopName)
                }
            }
        }
    }

    static func diff(current: [CompanionApproval], seen: Set<String>) -> [CompanionApproval] {
        current.filter { !seen.contains($0.id) }
    }

    static func clickPath(resource: String?) -> String {
        guard let resource = nonEmpty(resource) else { return "/companion/app/approvals" }
        let escaped = resource.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resource
        return "/companion/app/\(escaped)/approvals"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CompanionApprovalsSeenStore {
    let url: URL

    init(url: URL = AppPaths.supportDirectory.appendingPathComponent("approvals-seen.json")) {
        self.url = url
    }

    func load() -> Set<String>? {
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(ids)
    }

    func save(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class CompanionApprovalsMonitor: NSObject, WKNavigationDelegate {
    static let shared = CompanionApprovalsMonitor()

    private var webView: WKWebView?
    private var baseURL: URL?
    private var pollTask: Task<Void, Never>?
    private var failures = 0
    private let seenStore = CompanionApprovalsSeenStore()

    func start(baseURL: URL) {
        if self.baseURL == baseURL, webView != nil { return }
        stop()
        self.baseURL = baseURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        let target = CompanionConfig.targetURL(base: baseURL, path: nil) ?? baseURL
        webView.load(URLRequest(url: target))
        Task { await Notifications.shared.requestApprovalAuthorization() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        webView?.stopLoading()
        webView = nil
        baseURL = nil
        failures = 0
        OllieBadge.setApprovals(0)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        schedule(after: 2)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failures += 1
        schedule(after: backoff)
    }

    private var backoff: TimeInterval {
        let delays: [TimeInterval] = [60, 120, 300, 600]
        return delays[min(max(0, failures - 1), delays.count - 1)]
    }

    private func schedule(after seconds: TimeInterval) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.poll()
        }
    }

    private func poll() async {
        guard let webView, baseURL != nil else { return }
        let script = """
        const cookie = document.cookie.split('; ').find((c) => c.startsWith('XSRF-TOKEN='));
        const headers = { Accept: 'application/json' };
        if (cookie) headers['X-XSRF-TOKEN'] = decodeURIComponent(cookie.split('=').slice(1).join('='));
        try {
          const response = await fetch('/api/oo/approvals', { credentials: 'same-origin', headers });
          return { status: response.status, contentType: response.headers.get('content-type') || '', body: await response.text(), url: response.url };
        } catch (error) {
          return { status: 0, contentType: '', body: String(error), url: '' };
        }
        """
        let value: Any? = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let reply = value as? [String: Any],
              let status = reply["status"] as? Int, status == 200,
              let contentType = reply["contentType"] as? String, contentType.contains("application/json"),
              let body = reply["body"] as? String, let data = body.data(using: .utf8),
              let list = try? JSONDecoder().decode(CompanionApprovalsList.self, from: data) else {
            failures += 1
            schedule(after: backoff)
            return
        }

        failures = 0
        let approvals = CompanionApprovals.flatten(list)
        let pending = list.counts?.pending ?? approvals.count
        OllieBadge.setApprovals(pending)

        if let seen = seenStore.load() {
            for approval in CompanionApprovals.diff(current: approvals, seen: seen) {
                await notify(approval)
            }
            seenStore.save(seen.union(approvals.map(\.id)))
        } else {
            seenStore.save(Set(approvals.map(\.id)))
            if pending > 0 {
                await Notifications.shared.postApproval(
                    title: "\(pending) things waiting for your approval",
                    body: "Open Ollie to review them.",
                    id: "summary-\(Int(Date().timeIntervalSince1970))",
                    path: CompanionApprovals.clickPath(resource: nil))
            }
        }
        schedule(after: 60)
    }

    private func notify(_ approval: CompanionApproval) async {
        let body = [approval.question, approval.shopName].compactMap { $0 }.joined(separator: " · ")
        await Notifications.shared.postApproval(
            title: "\(approval.label) needs your approval",
            body: body,
            id: approval.id,
            path: approval.clickPath)
    }
}
