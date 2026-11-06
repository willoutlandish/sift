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
        let age_seconds: Int?
        let agent: Agent?
        let shop: ShopRef?
    }

    let shops: [Shop]
    let order: [String]?
    let counts: Counts?
}

struct CompanionTodoItem: Identifiable, Equatable {
    let id: String
    let label: String
    let title: String
    let age: String
    let clickPath: String
}

struct CompanionTodoShop: Identifiable, Equatable {
    let resource: String
    let name: String
    let pending: Int
    let items: [CompanionTodoItem]
    let more: Int

    var id: String { resource.isEmpty ? name : resource }
}

struct CompanionTodoSnapshot: Equatable {
    let total: Int
    let shops: [CompanionTodoShop]

    var isEmpty: Bool { total == 0 }
}

enum CompanionTodosState: Equatable {
    case loading
    case ready(CompanionTodoSnapshot)
    case signedOut
    case failed

    var showsEmpty: Bool {
        if case .ready(let snapshot) = self { return snapshot.total == 0 }
        return false
    }

    var showsError: Bool { self == .failed }
    var showsSignedOut: Bool { self == .signedOut }
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

enum CompanionTodos {
    static let pageSize = 5

    static func make(from list: CompanionApprovalsList) -> CompanionTodoSnapshot {
        let ranks = Dictionary(uniqueKeysWithValues: (list.order ?? []).enumerated().map { ($1, $0) })
        var shops: [CompanionTodoShop] = []
        var collected = 0

        for shop in list.shops {
            var items: [(index: Int, item: CompanionTodoItem)] = []
            for service in shop.services {
                for item in service.items {
                    guard !item.id.isEmpty else { continue }
                    let resource = nonEmpty(item.shop?.resource) ?? nonEmpty(shop.resource)
                    let label = nonEmpty(item.agent?.label) ?? nonEmpty(service.label) ?? "An agent"
                    let title = nonEmpty(item.question) ?? nonEmpty(item.kind) ?? nonEmpty(item.source) ?? "Approval"
                    let todo = CompanionTodoItem(id: item.id, label: label, title: title,
                                                 age: ageText(item.age_seconds),
                                                 clickPath: CompanionApprovals.clickPath(resource: resource))
                    items.append((items.count, todo))
                }
            }
            guard !items.isEmpty else { continue }
            collected += items.count
            let ordered = items.sorted { left, right in
                let leftRank = ranks[left.item.id] ?? Int.max
                let rightRank = ranks[right.item.id] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                return left.index < right.index
            }.map(\.item)
            shops.append(CompanionTodoShop(resource: shop.resource, name: shop.name,
                                           pending: ordered.count,
                                           items: Array(ordered.prefix(pageSize)),
                                           more: max(0, ordered.count - pageSize)))
        }

        return CompanionTodoSnapshot(total: list.counts?.pending ?? collected, shops: shops)
    }

    static func ageText(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "" }
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
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

struct CompanionFetchReply {
    let status: Int
    let contentType: String
    let body: String
    let url: String
}

@MainActor
final class CompanionApprovalsMonitor: NSObject, WKNavigationDelegate, ObservableObject {
    static let shared = CompanionApprovalsMonitor()

    @Published private(set) var state: CompanionTodosState = .loading
    private var webView: WKWebView?
    private var baseURL: URL?
    private var pollTask: Task<Void, Never>?
    private var failures = 0
    private var polling = false
    private let seenStore = CompanionApprovalsSeenStore()

    func start(baseURL: URL) {
        if self.baseURL == baseURL, webView != nil { return }
        stop()
        self.baseURL = baseURL
        state = .loading
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
        polling = false
        state = .loading
        OllieBadge.setApprovals(0)
    }

    func refresh() {
        pollTask?.cancel()
        pollTask = nil
        guard baseURL != nil else {
            state = .signedOut
            return
        }
        Task { await poll() }
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

    func fetch(path: String) async -> CompanionFetchReply? {
        guard let webView, baseURL != nil else { return nil }
        let encoded = (try? JSONSerialization.data(withJSONObject: [path]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"/\"]"
        let literal = String(encoded.dropFirst().dropLast())
        let script = """
        const path = \(literal);
        const cookie = document.cookie.split('; ').find((c) => c.startsWith('XSRF-TOKEN='));
        const headers = { Accept: 'application/json' };
        if (cookie) headers['X-XSRF-TOKEN'] = decodeURIComponent(cookie.split('=').slice(1).join('='));
        try {
          const response = await fetch(path, { credentials: 'same-origin', headers });
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
        guard let reply = value as? [String: Any] else { return nil }
        return CompanionFetchReply(status: reply["status"] as? Int ?? 0,
                                   contentType: reply["contentType"] as? String ?? "",
                                   body: reply["body"] as? String ?? "",
                                   url: reply["url"] as? String ?? "")
    }

    private func poll() async {
        guard !polling, baseURL != nil else { return }
        polling = true
        defer { polling = false }
        guard let reply = await fetch(path: "/api/oo/approvals") else {
            state = .failed
            failures += 1
            schedule(after: backoff)
            return
        }
        let finalURL = URL(string: reply.url)
        if reply.status == 401 || reply.status == 403 || reply.status == 419
            || (finalURL.map(CompanionSignInProbe.isSignIn) ?? false) {
            state = .signedOut
            OllieBadge.setApprovals(0)
            failures += 1
            schedule(after: backoff)
            return
        }
        guard reply.status == 200,
              reply.contentType.contains("application/json"),
              let data = reply.body.data(using: .utf8),
              let list = try? JSONDecoder().decode(CompanionApprovalsList.self, from: data) else {
            state = .failed
            failures += 1
            schedule(after: backoff)
            return
        }

        failures = 0
        let snapshot = CompanionTodos.make(from: list)
        state = .ready(snapshot)
        OllieBadge.setApprovals(snapshot.total)

        let approvals = CompanionApprovals.flatten(list)
        if let seen = seenStore.load() {
            for approval in CompanionApprovals.diff(current: approvals, seen: seen) {
                await notify(approval)
            }
            seenStore.save(seen.union(approvals.map(\.id)))
        } else {
            seenStore.save(Set(approvals.map(\.id)))
            if snapshot.total > 0 {
                await Notifications.shared.postApproval(
                    title: "\(snapshot.total) things waiting for your approval",
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
