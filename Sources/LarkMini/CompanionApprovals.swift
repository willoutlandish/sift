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

        struct Assignee: Decodable { let label: String?; let seat: String? }
        struct DecidedBy: Decodable { let reason: String? }
        let owner: Assignee?
        let case_assignee: Assignee?
        let decided_by: DecidedBy?
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

// Mirrors companion-approvals/OneTapDecision.tsx and control-room/board.ts.
enum CompanionApprovalEligibility {
    static func recipientsOf(_ item: CompanionApprovalsList.Item) -> [String] {
        (item.evidence ?? []).compactMap { fact in
            guard ["Recipient", "To"].contains(fact.label ?? ""),
                  let text = fact.text, !text.isEmpty else { return nil }
            return text
        }
    }

    static func draftText(_ item: CompanionApprovalsList.Item) -> String? {
        item.evidence?.first { $0.label == "Message to send" }?.text
    }

    static func isSendItem(_ item: CompanionApprovalsList.Item) -> Bool {
        ["send_approval", "creator_dm_reply"].contains(item.source ?? "")
    }

    static func cardAnswers(_ item: CompanionApprovalsList.Item) -> [String] {
        let answers = item.answers ?? []
        return recipientsOf(item).count > 1 ? answers.filter { $0 != "approve" } : answers
    }

    static func canApprove(_ item: CompanionApprovalsList.Item) -> Bool {
        item.can_answer == true && cardAnswers(item).contains("approve") &&
            (!isSendItem(item) || (!(item.send_version ?? "").isEmpty &&
                !(draftText(item) ?? "").isEmpty && recipientsOf(item).count == 1))
    }
    static func recommendation(_ item: CompanionApprovalsList.Item) -> String? {
        let value = item.recommendation?.value
        if let value, ["approve", "skip"].contains(value), item.can_answer == true,
           cardAnswers(item).contains(value), value != "approve" || canApprove(item) { return value }
        if value == nil, item.can_answer == true, !isSendItem(item), cardAnswers(item).contains("change"),
           !(item.recommendation?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty { return "change" }
        return nil
    }

    static func assigneeLine(_ item: CompanionApprovalsList.Item) -> String {
        let assignee = item.case_assignee ?? item.owner
        let seat = assignee?.seat?.replacingOccurrences(of: #"^AE_(FT|PT)$"#, with: "AE", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
        var name = assignee?.label ?? ""
        if let seat, !seat.isEmpty, name.hasSuffix(" (" + seat + ")") { name = String(name.dropLast(seat.count + 3)) }
        return [name.isEmpty ? nil : "Waiting on " + name, seat, ageLabel(item.age_seconds).lowercased()]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func ageLabel(_ seconds: Int?) -> String {
        guard let seconds else { return "" }
        if seconds < 60 { return "Just now" }
        let n = seconds < 3600 ? seconds / 60 : (seconds < 86400 ? seconds / 3600 : seconds / 86400)
        let unit = seconds < 3600 ? "minute" : (seconds < 86400 ? "hour" : "day")
        return "\(n) \(unit)" + (n == 1 ? "" : "s")
    }

    static func safeHref(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0.value == 92 }) else { return nil }
        if value.hasPrefix("/") { return value.hasPrefix("//") ? nil : value }
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return value
    }

}

struct CompanionDecisionTarget: Equatable {
    let id: String
    let version: String?
    let sendVersion: String?
}

struct CompanionConfirmationTarget: Equatable {
    let id: String
    let version: String?
    let sendVersion: String?
    let draft: String?
    let recipients: [String]
    let answers: [String]
}

struct CompanionTodoItem: Identifiable, Equatable {
    let id: String
    let label: String
    let title: String
    let age: String
    let clickPath: String
    let answers: [String]
    let canAnswer: Bool
    let recipients: [String]
    let canApprove: Bool
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
    let recommendationAnswer: String?
    let assigneeLine: String
    let decidedReason: String?
    let itemLink: String?
    let shopName: String
    let resource: String

    var confirmationTarget: CompanionConfirmationTarget {
        .init(id: id, version: decision?.version, sendVersion: decision?.sendVersion,
              draft: payloadPreview, recipients: recipients, answers: answers)
    }

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
        let waitingOnly = ageSeconds != nil && (statusReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^waiting\s+(?:for\s+)?(?:\d+(?:\.\d+)?\s*(?:s|sec(?:ond)?s?|m|min(?:ute)?s?|h|hours?|d|days?)\s*)+\.?$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil)
        return [needsYouBecause, waitingOnly ? nil : statusReason, decidedReason]
            .compactMap { $0 }.first { !$0.isEmpty }
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
    let allItems: [CompanionTodoItem]

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
        guard let resource = nonEmpty(resource), resource != ".", resource != ".." else {
            return "/companion/app/approvals"
        }
        return "/companion/app/\(CompanionActivity.escape(resource))/approvals"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CompanionTodos {
    static func make(from list: CompanionApprovalsList) -> CompanionTodoSnapshot {
        let ranks = Dictionary((list.order ?? []).enumerated().map { ($1, $0) },
                               uniquingKeysWith: { first, _ in first })
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
                    let offered = CompanionApprovalEligibility.cardAnswers(item)
                    let preview = CompanionApprovalEligibility.draftText(item)
                    let target = CompanionDecisionTarget(id: item.id, version: item.version,
                                                         sendVersion: item.send_version)
                    let todo = CompanionTodoItem(
                        id: item.id, label: label, title: title,
                        age: ageText(item.age_seconds),
                        clickPath: CompanionApprovals.clickPath(resource: resource),
                        answers: offered,
                        canAnswer: item.can_answer ?? false,
                        recipients: CompanionApprovalEligibility.recipientsOf(item),
                        canApprove: CompanionApprovalEligibility.canApprove(item),
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
                        recommendationAnswer: CompanionApprovalEligibility.recommendation(item),
                        assigneeLine: CompanionApprovalEligibility.assigneeLine(item),
                        decidedReason: item.decided_by?.reason,
                        itemLink: CompanionApprovalEligibility.safeHref(item.link),
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
                                           allItems: ordered))
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
    static func decisionRequest(item: CompanionTodoItem, answer: String, text: String? = nil) -> CompanionDecisionRequest? {
        guard let target = item.decision, item.canAnswer, item.answers.contains(answer),
              answer != "approve" || item.canApprove else { return nil }
            let rows: [[String: Any]] = [[
                "id": target.id,
                "version": target.version ?? NSNull(),
                "send_version": target.sendVersion ?? NSNull()
            ]]
            var body: [String: Any] = ["items": rows, "answer": answer]
            if let text { body["text"] = text }
            return CompanionDecisionRequest(path: "/api/oo/approvals/answer", body: body)

    }


}

enum CompanionDecisionOutcomeParser {
    static func outcome(itemId: String, answer: String,
                        reply: CompanionFetchReply?) -> CompanionDecisionOutcome {
        guard let reply else { return CompanionDecisionOutcome(message: "Couldn't reach Companion.", remove: false) }
            guard reply.status == 200,
                  let data = reply.body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let message = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any])?["message"] as? String
                return CompanionDecisionOutcome(message: message ?? "Couldn't save that decision.", remove: false)
            }
            guard let results = object["results"] as? [[String: Any]],
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

    }


}

@MainActor
final class CompanionApprovalsActions {
    static let shared = CompanionApprovalsActions()

    func submit(item: CompanionTodoItem, answer: String, text: String? = nil) async -> CompanionDecisionOutcome {
        if CompanionApprovalsMonitor.shared.isReadOnly {
            return CompanionDecisionOutcome(message: CompanionWriteGuard.refusal, remove: false)
        }
        guard let request = CompanionDecisionRequests.decisionRequest(item: item, answer: answer, text: text) else {
            return CompanionDecisionOutcome(message: "This item can't be answered here.", remove: false)
        }
        let reply = await CompanionApprovalsMonitor.shared.postJSON(path: request.path, body: request.body)
        return CompanionDecisionOutcomeParser.outcome(itemId: item.id, answer: answer, reply: reply)
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
        let capped = ids.sorted().suffix(2_000)
        guard let data = try? JSONEncoder().encode(Array(capped)) else { return }
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
    @Published private(set) var shopNames: [String: String] = [:]
    @Published private(set) var paceTotals: CompanionPaceTotals?
    @Published private(set) var paceState: CompanionPaceState = .unknown
    private var webView: WKWebView?
    private var baseURL: URL?
    private var pollTask: Task<Void, Never>?
    private var failures = 0
    private var polling = false
    private var paceRefreshing = false
    private var pageReady: CheckedContinuation<Void, Never>?
    private let seenStore = CompanionApprovalsSeenStore()
    private static let scriptWorld = WKContentWorld.world(name: "ollie")

    var isReadOnly: Bool { CompanionWriteGuard.isReadOnly(baseURL: baseURL) }

    func start(baseURL: URL) {
        if self.baseURL == baseURL, let webView {
            if !isOnBase(webView.url) { webView.load(URLRequest(url: baseURL)) }
            return
        }
        stop()
        self.baseURL = baseURL
        state = .loading
        let configuration = CompanionWebConfiguration.make()
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
        shopNames = [:]
        paceTotals = nil
        paceState = .unknown
        OllieBadge.setApprovals(0)
    }

    func refresh() {
        pollTask?.cancel()
        pollTask = nil
        guard let baseURL else {
            state = .signedOut
            return
        }
        if webView == nil {
            start(baseURL: baseURL)
            return
        }
        if let webView, !isOnBase(webView.url) {
            webView.load(URLRequest(url: baseURL))
        }
        Task { await poll() }
    }

    func wake() {
        failures = 0
        refresh()
    }

    private func isOnBase(_ url: URL?) -> Bool {
        guard let url, let baseURL else { return false }
        return CompanionConfig.originMatches(scheme: url.scheme ?? "", host: url.host ?? "",
                                             port: url.port ?? 0, base: baseURL)
    }

    private func ensureBasePage() async {
        guard let webView, let baseURL, !isOnBase(webView.url) else { return }
        await withCheckedContinuation { continuation in
            pageReady = continuation
            webView.load(URLRequest(url: baseURL))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let ready = self.pageReady else { return }
                self.pageReady = nil
                ready.resume()
            }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let baseURL,
              let url = navigationAction.request.url,
              CompanionConfig.originMatches(scheme: url.scheme ?? "", host: url.host ?? "",
                                            port: url.port ?? 0, base: baseURL) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failures = 0
        if let ready = pageReady {
            pageReady = nil
            ready.resume()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failures += 1
        let url = baseURL
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self, let url, self.baseURL == url else { return }
            self.webView?.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        schedule(after: 2)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failures += 1
        let base = baseURL
        schedule(after: backoff)
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self, let base, self.baseURL == base else { return }
            self.webView?.load(URLRequest(url: base))
        }
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
        await ensureBasePage()
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
        let value: Any? = await runJavaScript(script)
        guard let reply = value as? [String: Any] else { return nil }
        return CompanionFetchReply(status: reply["status"] as? Int ?? 0,
                                   contentType: reply["contentType"] as? String ?? "",
                                   body: reply["body"] as? String ?? "",
                                   url: reply["url"] as? String ?? "")
    }

    func postJSON(path: String, body: [String: Any]) async -> CompanionFetchReply? {
        OllieUpdates.shared.beginDecision()
        defer { OllieUpdates.shared.endDecision() }
        guard !isReadOnly else { return nil }
        guard let webView, baseURL != nil else { return nil }
        await ensureBasePage()
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
        let value: Any? = await runJavaScript(script)
        guard let reply = value as? [String: Any] else { return nil }
        return CompanionFetchReply(status: reply["status"] as? Int ?? 0,
                                   contentType: reply["contentType"] as? String ?? "",
                                   body: reply["body"] as? String ?? "",
                                   url: reply["url"] as? String ?? "")
    }

    private static let fetchTimeout: TimeInterval = 15

    private func runJavaScript(_ script: String) async -> Any? {
        guard let webView else { return nil }
        let gate = FetchGate()
        return await withCheckedContinuation { continuation in
            gate.set(continuation)
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: Self.scriptWorld) { result in
                switch result {
                case .success(let value): gate.finish(value)
                case .failure: gate.finish(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fetchTimeout) {
                gate.finish(nil)
            }
        }
    }

    private func poll() async {
        guard !polling, baseURL != nil else { return }
        polling = true
        defer { polling = false }
        guard let reply = await fetch(path: "/api/oo/approvals") else {
            if case .ready = state {} else { state = .failed }
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
            if case .ready = state {} else { state = .failed }
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
            if Notifications.shared.enabled, Notifications.shared.access == .authorized {
                seenStore.save(seen.union(approvals.map(\.id)))
            }
        } else {
            if Notifications.shared.enabled, Notifications.shared.access == .authorized {
                seenStore.save(Set(approvals.map(\.id)))
            }
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

    @discardableResult
    func refreshPaceNow() async -> (status: Int, paceState: CompanionPaceState, shops: [CompanionShopPace]) {
        guard !paceRefreshing else { return (0, paceState, Array(pace.values)) }
        paceRefreshing = true
        defer { paceRefreshing = false }
        guard let reply = await fetch(path: CompanionPace.path) else {
            if pace.isEmpty { paceState = .failed }
            return (0, paceState, Array(pace.values))
        }
        let state = CompanionPaceState.from(status: reply.status)
        if state == .available, let payload = CompanionPace.parse(reply.body) {
            pace = payload.shops
            shopNames = payload.shopNames
            paceTotals = payload.totals
            paceState = .available
        } else if state == .hidden {
            pace = [:]
        shopNames = [:]
            paceTotals = nil
            paceState = .hidden
        } else if pace.isEmpty { paceState = .failed }
        return (reply.status, paceState, pace.values.sorted { $0.name < $1.name })
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


private final class FetchGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Any?, Never>?
    private var finished = false

    func set(_ continuation: CheckedContinuation<Any?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ value: Any?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
