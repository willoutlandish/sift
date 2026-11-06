import Foundation

struct CompanionShopActivity: Decodable {
    struct Tab: Decodable {
        struct Now: Decodable {
            struct Step: Decodable {
                let text: String?
                let at: String?
                let is_error: Bool?
            }
            let source: String?
            let kind: String?
            let label: String?
            let since: String?
            let step: Step?
        }
        struct Waiting: Decodable {
            let code: String?
            let label: String?
            let since: String?
        }
        struct LastRun: Decodable {
            let state: String?
            let at: String?
        }

        let agent: String
        let name: String?
        let role: String?
        let state: String?
        let now: Now?
        let waiting: Waiting?
        let last_run: LastRun?
    }

    let tabs: [Tab]
    let ollie: Bool?
}

struct CompanionAgentActivity: Decodable {
    struct Event: Decodable {
        let at: String?
        let text: String?
    }

    let events: [Event]
}

struct CompanionActivityAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let role: String?
    let state: String
    let current: String
    let since: String?
    let waiting: String?
    let lines: [String]
    let latestAt: String?
}

enum CompanionActivityAvailability: Equatable {
    case unknown
    case available
    case unavailable

    static func from(status: Int) -> CompanionActivityAvailability {
        switch status {
        case 200: return .available
        case 404: return .unavailable
        default: return .unknown
        }
    }
}

enum CompanionActivityState: Equatable {
    case idle
    case loading
    case ready([CompanionActivityAgent])
    case failed

    var showsError: Bool { self == .failed }
}

enum CompanionActivityLoad: Equatable {
    case unavailable
    case failed
    case ready([CompanionActivityAgent])
}

enum CompanionActivityParser {
    static func parse(shopStatus: Int, shopBody: String?, eventBodies: [String: String]) -> CompanionActivityLoad {
        if shopStatus == 404 { return .unavailable }
        guard shopStatus == 200,
              let shopBody, let data = shopBody.data(using: .utf8),
              let shop = try? JSONDecoder().decode(CompanionShopActivity.self, from: data) else {
            return .failed
        }
        let agents = shop.tabs.map { tab -> CompanionActivityAgent in
            let events = eventBodies[tab.agent]
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CompanionAgentActivity.self, from: $0) }?
                .events ?? []
            let lines = events.sorted { ($0.at ?? "") > ($1.at ?? "") }
                .compactMap { nonEmpty($0.text) }
                .prefix(3)
            let now = tab.now
            let current = nonEmpty(now?.step?.text) ?? nonEmpty(now?.label)
                ?? nonEmpty(tab.waiting?.label) ?? nonEmpty(tab.state) ?? "Idle"
            let since = nonEmpty(now?.since) ?? nonEmpty(now?.step?.at)
                ?? nonEmpty(tab.waiting?.since) ?? nonEmpty(tab.last_run?.at)
            return CompanionActivityAgent(
                id: tab.agent,
                name: nonEmpty(tab.name) ?? tab.agent,
                role: nonEmpty(tab.role),
                state: nonEmpty(tab.state) ?? "idle",
                current: current,
                since: since,
                waiting: nonEmpty(tab.waiting?.label),
                lines: Array(lines),
                latestAt: since ?? events.compactMap(\.at).max())
        }.sorted { ($0.latestAt ?? "") > ($1.latestAt ?? "") }
        return .ready(agents)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CompanionActivityFormat {
    static func ago(_ value: String?) -> String {
        guard let value, let date = parse(value) else { return "" }
        return CompanionTodos.ageText(max(0, Int(Date().timeIntervalSince(date))))
    }

    private static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

@MainActor
final class CompanionActivity: ObservableObject {
    static let shared = CompanionActivity()

    @Published private(set) var availability: CompanionActivityAvailability = .unknown
    @Published private(set) var state: CompanionActivityState = .idle

    private var resource: String?
    private var task: Task<Void, Never>?
    private var refreshing = false

    func detect(resource: String) async {
        guard availability == .unknown else { return }
        guard let reply = await CompanionApprovalsMonitor.shared.fetch(path: Self.shopPath(resource)) else { return }
        availability = CompanionActivityAvailability.from(status: reply.status)
    }

    func start(resource: String) {
        if self.resource == resource, task != nil { return }
        stop()
        self.resource = resource
        state = .loading
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        resource = nil
        refreshing = false
        state = .idle
    }

    func retry() {
        Task { await refresh() }
    }

    private func refresh() async {
        guard !refreshing, let resource else { return }
        refreshing = true
        defer { refreshing = false }
        guard let reply = await CompanionApprovalsMonitor.shared.fetch(path: Self.shopPath(resource)) else {
            state = .failed
            return
        }
        if reply.status == 404 {
            availability = .unavailable
            state = .idle
            task?.cancel()
            task = nil
            return
        }
        guard reply.status == 200 else {
            state = .failed
            return
        }
        availability = .available
        var eventBodies: [String: String] = [:]
        if let data = reply.body.data(using: .utf8),
           let shop = try? JSONDecoder().decode(CompanionShopActivity.self, from: data) {
            for tab in shop.tabs {
                let path = Self.agentPath(resource: resource, agent: tab.agent)
                if let eventReply = await CompanionApprovalsMonitor.shared.fetch(path: path), eventReply.status == 200 {
                    eventBodies[tab.agent] = eventReply.body
                }
            }
        }
        switch CompanionActivityParser.parse(shopStatus: reply.status, shopBody: reply.body,
                                             eventBodies: eventBodies) {
        case .unavailable:
            availability = .unavailable
            state = .idle
        case .failed:
            state = .failed
        case .ready(let agents):
            state = .ready(agents)
        }
    }

    static func shopPath(_ resource: String) -> String {
        "/api/oo/shops/\(escape(resource))/agents/activity"
    }

    static func agentPath(resource: String, agent: String) -> String {
        "/api/oo/shops/\(escape(resource))/agents/\(escape(agent))/activity"
    }

    static func agentPagePath(resource: String, agent: String) -> String {
        "/companion/app/\(escape(resource))/agents/\(escape(agent))/home"
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
