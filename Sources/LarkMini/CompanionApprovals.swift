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
        struct Recommendation: Decodable { let text: String?; let value: String? }
        struct Evidence: Decodable { let label: String?; let text: String?; let url: String? }
        struct Priority: Decodable {
            struct Target: Decodable { let state: String? }
            let score: Double?
            let band: String?
            let risk: String?
            let risk_reason: String?
            let reasons: [String]?
            let tip: String?
            let target: Target?
        }

        let id: String
        let source: String?
        let kind: String?
        let question: String?
        let age_seconds: Int?
        let agent: Agent?
        let shop: ShopRef?
        let version: String?
        let send_version: String?
        let can_answer: Bool?
        let answers: [String]?
        let recommendation: Recommendation?
        let status: String?
        let status_reason: String?
        let needs_you_because: String?
        let content_sha256: String?
        let draft_kind: String?
        let draft_id: Int?
        let send_type: String?
        let content_clear: Bool?
        let can_decide: Bool?
        let preview: String?
        let evidence: [Evidence]?
        let link: String?
        let priority: Priority?
        let expires_at: String?
        let opened_at: String?
        let waiting_on: String?
        let mine: Bool?
    }

    let shops: [Shop]
    let order: [String]?
    let counts: Counts?
}

struct CompanionDecisionTarget: Equatable {
    enum API: Equatable {
        case answers
        case shop
    }

    let api: API
    let id: String
    let resource: String?
    let version: String?
    let sendVersion: String?
    let contentSha256: String?
    let draftKind: String?
    let draftId: Int?
    let sendType: String?
}

struct CompanionTodoItem: Identifiable, Equatable {
    let id: String
    let label: String
    let title: String
    let age: String
    let clickPath: String
    let answers: [String]
    let canAnswer: Bool
    let disabledReason: String?
    let payloadPreview: String?
    let decision: CompanionDecisionTarget?
    let source: String
    let kind: String
    let statusReason: String?
    let needsYouBecause: String?
    let priorityBand: String?
    let priorityReasons: [String]
    let priorityTip: String?
    let expiresAt: String?
    let ageSeconds: Int?
    let recommendation: String?
    let shopName: String
    let resource: String

    var categoryKey: String {
        let raw = kind.isEmpty ? source : kind
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var categoryLabel: String {
        let raw = categoryKey
        guard !raw.isEmpty else { return "Other" }
        return raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var reason: String? {
        [statusReason, needsYouBecause, recommendation, priorityReasons.first]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var isOlder: Bool { (ageSeconds ?? 0) >= 7 * 86_400 }
}

struct CompanionDecisionRequest: Equatable {
    let path: String
    let body: [String: Any]

    static func == (left: CompanionDecisionRequest, right: CompanionDecisionRequest) -> Bool {
        left.path == right.path && NSDictionary(dictionary: left.body).isEqual(to: right.body)
    }
}

struct CompanionDecisionOutcome: Equatable {
    let message: String
    let remove: Bool
}

struct CompanionTodoShop: Identifiable, Equatable {
    let resource: String
    let name: String
    let pending: Int
    let items: [CompanionTodoItem]
    let allItems: [CompanionTodoItem]
    let more: Int

    var id: String { resource.isEmpty ? name : resource }
}

struct CompanionTodoSnapshot: Equatable {
    let total: Int
    let shops: [CompanionTodoShop]
    let orderedItems: [CompanionTodoItem]

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
                    let shopName = nonEmpty(item.shop?.name) ?? nonEmpty(shop.name)
                    let label = nonEmpty(item.agent?.label) ?? nonEmpty(service.label) ?? "An agent"
                    let title = nonEmpty(item.question) ?? nonEmpty(item.kind) ?? nonEmpty(item.source) ?? "Approval"
                    let offered = item.answers ?? (item.can_decide == true ? ["approve", "skip"] : [])
                    let preview = nonEmpty(item.preview)
                        ?? nonEmpty(item.evidence?.first { $0.label == "Message to send" }?.text)
                        ?? nonEmpty(item.recommendation?.text)
                    let target = CompanionDecisionTarget(
                        api: item.content_sha256 == nil ? .answers : .shop,
                        id: item.id,
                        resource: resource,
                        version: item.version,
                        sendVersion: item.send_version,
                        contentSha256: item.content_sha256,
                        draftKind: item.draft_kind,
                        draftId: item.draft_id,
                        sendType: item.send_type)
                    let todo = CompanionTodoItem(
                        id: item.id, label: label, title: title,
                        age: ageText(item.age_seconds),
                        clickPath: CompanionApprovals.clickPath(resource: resource),
                        answers: offered,
                        canAnswer: item.can_answer ?? item.can_decide ?? false,
                        disabledReason: item.content_clear == false
                            ? "This reply has nothing to send. Skip it or ask for a change." : nil,
                        payloadPreview: preview,
                        decision: target,
                        source: item.source ?? "",
                        kind: item.kind ?? "",
                        statusReason: item.status_reason,
                        needsYouBecause: item.needs_you_because,
                        priorityBand: item.priority?.band,
                        priorityReasons: item.priority?.reasons ?? [],
                        priorityTip: item.priority?.tip,
                        expiresAt: item.expires_at,
                        ageSeconds: item.age_seconds,
                        recommendation: item.recommendation?.text,
                        shopName: shopName ?? shop.name,
                        resource: resource ?? shop.resource)
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
                                           allItems: ordered,
                                           more: max(0, ordered.count - pageSize)))
        }

        let allItems = shops.flatMap(\.allItems)
        let orderedItems = allItems.sorted { left, right in
            let leftRank = ranks[left.id] ?? Int.max
            let rightRank = ranks[right.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return false
        }
        return CompanionTodoSnapshot(total: list.counts?.pending ?? collected,
                                     shops: shops, orderedItems: orderedItems)
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

enum CompanionDecisionRequests {
    static func decisionRequest(item: CompanionTodoItem, answer: String) -> CompanionDecisionRequest? {
        guard let target = item.decision, item.canAnswer else { return nil }
        switch target.api {
        case .answers:
            let rows: [[String: Any]] = [[
                "id": target.id,
                "version": target.version ?? NSNull(),
                "send_version": target.sendVersion ?? NSNull()
            ]]
            return CompanionDecisionRequest(
                path: "/api/oo/approvals/answer",
                body: ["items": rows, "answer": answer])
        case .shop:
            guard let resource = target.resource,
                  let kind = target.draftKind,
                  let id = target.draftId,
                  let sendType = target.sendType,
                  let hash = target.contentSha256 else { return nil }
            return CompanionDecisionRequest(
                path: "/api/oo/shops/\(resource.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resource)/companion/approvals",
                body: [
                    "draft_kind": kind,
                    "draft_id": id,
                    "send_type": sendType,
                    "content_sha256": hash,
                    "decision": answer == "approve" ? "approved" : "refused"
                ])
        }
    }

    static func batchRequest(items: [CompanionTodoItem], answer: String) -> CompanionDecisionRequest? {
        guard !items.isEmpty else { return nil }
        var rows: [[String: Any]] = []
        for item in items {
            guard let target = item.decision, target.api == .answers, item.canAnswer else { return nil }
            rows.append([
                "id": target.id,
                "version": target.version ?? NSNull(),
                "send_version": target.sendVersion ?? NSNull()
            ])
        }
        return CompanionDecisionRequest(
            path: "/api/oo/approvals/answer",
            body: ["items": rows, "answer": answer])
    }
}

enum CompanionDecisionOutcomeParser {
    static func outcome(api: CompanionDecisionTarget.API, itemId: String, answer: String,
                        reply: CompanionFetchReply?) -> CompanionDecisionOutcome {
        guard let reply else { return CompanionDecisionOutcome(message: "Couldn't reach Companion.", remove: false) }
        switch api {
        case .answers:
            guard reply.status == 200,
                  let data = reply.body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = object["results"] as? [[String: Any]],
                  let result = results.first(where: { $0["id"] as? String == itemId }) else {
                return CompanionDecisionOutcome(message: "Couldn't save that decision.", remove: false)
            }
            let status = result["status"] as? String ?? "failed"
            let message = result["message"] as? String
            switch status {
            case "ok":
                return CompanionDecisionOutcome(message: message ?? (answer == "approve" ? "Approved" : "Declined"),
                                                remove: true)
            case "stale":
                return CompanionDecisionOutcome(message: message ?? "Changed, reload", remove: false)
            case "forbidden":
                return CompanionDecisionOutcome(message: message ?? "You can't answer this one", remove: false)
            default:
                return CompanionDecisionOutcome(message: message ?? "Couldn't save that decision.", remove: false)
            }
        case .shop:
            guard (200..<300).contains(reply.status) else {
                let message = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any])?["message"] as? String
                return CompanionDecisionOutcome(message: message ?? "Couldn't save that decision.", remove: false)
            }
            return CompanionDecisionOutcome(message: answer == "approve" ? "Approved" : "Declined", remove: true)
        }
    }

    static func batchOutcome(itemIds: [String], answer: String, reply: CompanionFetchReply?) -> CompanionDecisionOutcome {
        guard let reply else { return CompanionDecisionOutcome(message: "Couldn't reach Companion.", remove: false) }
        guard reply.status == 200,
              let data = reply.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            return CompanionDecisionOutcome(message: "Couldn't save those decisions.", remove: false)
        }
        let failures = results.filter { ($0["status"] as? String) != "ok" }
        if let first = failures.first {
            let message = first["message"] as? String
            return CompanionDecisionOutcome(message: message ?? "Couldn't save every decision.", remove: false)
        }
        let count = itemIds.count
        return CompanionDecisionOutcome(message: answer == "approve" ? "Approved \(count)" : "Declined \(count)",
                                        remove: true)
    }
}

@MainActor
final class CompanionApprovalsActions {
    static let shared = CompanionApprovalsActions()

    func submit(item: CompanionTodoItem, answer: String) async -> CompanionDecisionOutcome {
        if CompanionApprovalsMonitor.shared.isReadOnly {
            return CompanionDecisionOutcome(message: CompanionWriteGuard.refusal, remove: false)
        }
        guard let request = CompanionDecisionRequests.decisionRequest(item: item, answer: answer),
              let api = item.decision?.api else {
            return CompanionDecisionOutcome(message: "This item can't be answered here.", remove: false)
        }
        let reply = await CompanionApprovalsMonitor.shared.postJSON(path: request.path, body: request.body)
        return CompanionDecisionOutcomeParser.outcome(api: api, itemId: item.id, answer: answer, reply: reply)
    }

    func submitBatch(items: [CompanionTodoItem], answer: String) async -> CompanionDecisionOutcome {
        if CompanionApprovalsMonitor.shared.isReadOnly {
            return CompanionDecisionOutcome(message: CompanionWriteGuard.refusal, remove: false)
        }
        guard let request = CompanionDecisionRequests.batchRequest(items: items, answer: answer) else {
            return CompanionDecisionOutcome(message: "These items can't be answered here.", remove: false)
        }
        let reply = await CompanionApprovalsMonitor.shared.postJSON(path: request.path, body: request.body)
        return CompanionDecisionOutcomeParser.batchOutcome(itemIds: items.map(\.id), answer: answer, reply: reply)
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
    @Published private(set) var pace: [String: CompanionShopPace] = [:]
    @Published private(set) var paceState: CompanionPaceState = .unknown
    private var webView: WKWebView?
    private var baseURL: URL?
    private var pollTask: Task<Void, Never>?
    private var failures = 0
    private var polling = false
    private var paceRefreshing = false
    private let seenStore = CompanionApprovalsSeenStore()

    var isReadOnly: Bool { CompanionWriteGuard.isReadOnly(baseURL: baseURL) }

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
        paceRefreshing = false
        state = .loading
        pace = [:]
        paceState = .unknown
        OllieBadge.setApprovals(0)
    }

    func refresh() {
        pollTask?.cancel()
        pollTask = nil
        guard baseURL != nil else {
            state = .signedOut
            return
        }
        Task {
            await refreshPaceNow()
            await poll()
        }
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

    func postJSON(path: String, body: [String: Any]) async -> CompanionFetchReply? {
        guard !isReadOnly else { return nil }
        guard let webView, baseURL != nil else { return nil }
        guard let pathData = try? JSONSerialization.data(withJSONObject: [path]),
              let pathArray = String(data: pathData, encoding: .utf8),
              let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let bodyJSON = String(data: bodyData, encoding: .utf8),
              let bodyArrayData = try? JSONSerialization.data(withJSONObject: [bodyJSON]),
              let bodyArray = String(data: bodyArrayData, encoding: .utf8) else { return nil }
        let pathLiteral = String(pathArray.dropFirst().dropLast())
        let bodyLiteral = String(bodyArray.dropFirst().dropLast())
        let script = """
        const path = \(pathLiteral);
        const payload = \(bodyLiteral);
        const cookie = document.cookie.split('; ').find((c) => c.startsWith('XSRF-TOKEN='));
        const headers = { Accept: 'application/json', 'Content-Type': 'application/json' };
        if (cookie) headers['X-XSRF-TOKEN'] = decodeURIComponent(cookie.split('=').slice(1).join('='));
        try {
          const response = await fetch(path, { method: 'POST', credentials: 'same-origin', headers, body: payload });
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
        await refreshPaceNow()

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

    func probePace() async -> (status: Int, paceState: CompanionPaceState, shops: [CompanionShopPace]) {
        guard let reply = await fetch(path: CompanionPace.path) else {
            return (0, paceState, [])
        }
        let state = CompanionPaceState.from(status: reply.status)
        guard state == .available, let parsed = CompanionPace.parse(reply.body) else {
            pace = [:]
            paceState = state == .hidden ? .hidden : .failed
            return (reply.status, paceState, [])
        }
        pace = parsed
        paceState = .available
        return (reply.status, .available, parsed.values.sorted { $0.name < $1.name })
    }

    func refreshPaceNow() async {
        guard !paceRefreshing else { return }
        paceRefreshing = true
        defer { paceRefreshing = false }
        paceState = .unknown
        guard let reply = await fetch(path: CompanionPace.path) else {
            paceState = .failed
            return
        }
        switch CompanionPaceState.from(status: reply.status) {
        case .available:
            guard let parsed = CompanionPace.parse(reply.body) else {
                paceState = .failed
                return
            }
            pace = parsed
            paceState = .available
        case .hidden:
            pace = [:]
            paceState = .hidden
        case .failed, .unknown:
            paceState = .failed
        }
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
