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
        let next_check_at: String?
    }

    let tabs: [Tab]
    let ollie: Bool?
}

struct CompanionAgentActivity: Decodable {
    struct Event: Decodable {
        let at: String?
        let text: String?
    }
    struct Story: Decodable {
        let headline: String?
        let sentence: String?
    }
    struct Run: Decodable {
        let run_id: String?
        let state: String?
        let outcome: String?
        let started_at: String?
        let finished_at: String?
        let story: Story?
    }
    struct Drawer: Decodable {
        struct NextUp: Decodable {
            let next_check_at: String?
            let drafts_waiting: Int?
        }
        let runs_48h: Int?
        let ok_48h: Int?
        let partial_48h: Int?
        let failed_48h: Int?
        let drafts_waiting: Int?
        let next_up: NextUp?
    }

    let events: [Event]?
    let runs: [Run]?
    let drawer: Drawer?
    let next_check_at: String?
}

enum CompanionRunMark: String, Equatable {
    case ok
    case partial
    case failed
    case running
}

struct CompanionActivityAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let role: String?
    let state: String
    let current: String
    let since: String?
    let waiting: String?
    let lastRunSummary: String?
    let lastRunAt: String?
    var lastRunOutcome: String? = nil
    let sparkline: [CompanionRunMark]
    let runs48h: Int?
    let ok48h: Int?
    let partial48h: Int?
    let failed48h: Int?
    let nextCheckAt: String?
    let draftsWaiting: Int?
}

enum CompanionShopActivitySummary: Equatable {
    case unavailable
    case failed
    case ready(agents: Int, working: Int)
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
            let activity = eventBodies[tab.agent]
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CompanionAgentActivity.self, from: $0) }
            let runs = activity?.runs ?? []
            let now = tab.now
            let current = nonEmpty(now?.step?.text) ?? nonEmpty(now?.label)
                ?? nonEmpty(tab.waiting?.label) ?? nonEmpty(tab.state) ?? "Idle"
            let since = nonEmpty(now?.since) ?? nonEmpty(now?.step?.at)
                ?? nonEmpty(tab.waiting?.since) ?? nonEmpty(tab.last_run?.at)
            let sparkline = runs.prefix(12).map { run -> CompanionRunMark in
                let state = (run.state ?? "").lowercased()
                let outcome = (run.outcome ?? "").lowercased()
                if state == "running" || state == "queued" { return .running }
                if state == "failed" || state == "error" || outcome.contains("fail") || ["blocked", "timeout", "provider_error", "infra_error"].contains(outcome) { return .failed }
                if state == "partial" || outcome.contains("partial") { return .partial }
                if state == "ok" || state == "success" || outcome.contains("ok") { return .ok }
                return .running
            }
            let lastRun = runs.first
            let lastRunSummary = nonEmpty(lastRun?.story?.headline) ?? nonEmpty(lastRun?.story?.sentence)
            let lastRunAt = nonEmpty(lastRun?.started_at) ?? nonEmpty(lastRun?.finished_at) ?? nonEmpty(tab.last_run?.at)
            let drawer = activity?.drawer
            let nextCheck = nonEmpty(activity?.next_check_at) ?? nonEmpty(drawer?.next_up?.next_check_at)
                ?? nonEmpty(tab.next_check_at)
            return CompanionActivityAgent(
                id: tab.agent,
                name: nonEmpty(tab.name) ?? tab.agent,
                role: nonEmpty(tab.role),
                state: nonEmpty(tab.state) ?? "idle",
                current: current,
                since: since,
                waiting: nonEmpty(tab.waiting?.label),
                lastRunSummary: lastRunSummary,
                lastRunAt: lastRunAt,
                lastRunOutcome: lastRun?.outcome ?? lastRun?.state,
                sparkline: Array(sparkline),
                runs48h: drawer?.runs_48h,
                ok48h: drawer?.ok_48h,
                partial48h: drawer?.partial_48h,
                failed48h: drawer?.failed_48h,
                nextCheckAt: nextCheck,
                draftsWaiting: drawer?.drafts_waiting ?? drawer?.next_up?.drafts_waiting)
        }
        return .ready(agents)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CompanionActivityFormat {
    // Mirrors worker-summary.ts agoWords and untilShort.
    static func ago(_ value: String?, now: Date = Date()) -> String {
        guard let value, let date = parse(value) else { return "" }
        let minutes = max(0, Int(floor(now.timeIntervalSince(date) / 60 + 0.5)))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int(floor(Double(minutes) / 60 + 0.5))
        return hours < 48 ? "\(hours) h ago" : "\(Int(floor(Double(hours) / 24 + 0.5))) days ago"
    }

    static func until(_ value: String?, now: Date = Date()) -> String {
        guard let value, let date = parse(value) else { return "" }
        let minutes = Int(floor(date.timeIntervalSince(now) / 60 + 0.5))
        func span(_ n: Int) -> String { n >= 90 ? "\(Int(floor(Double(n) / 60 + 0.5))) h" : "\(n) min" }
        if minutes >= 1 { return "in " + span(minutes) }
        if minutes > -2 { return "now" }
        return span(-minutes) + " late"
    }

    static func outcome(_ value: String) -> String {
        ["running": "Running", "ok": "Done", "partial": "Finished with gaps",
         "blocked": "Blocked", "timeout": "Timed out", "provider_error": "Model failed",
         "infra_error": "Runner failed"][value] ?? value
    }

    static func parse(_ value: String) -> Date? {
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
    @Published private(set) var lastRead: Date?
    @Published private(set) var summaries: [String: CompanionShopActivitySummary] = [:]
    private var summaryLoading = Set<String>()
    private var summaryFetched: [String: Date] = [:]
    private var availabilityByResource: [String: CompanionActivityAvailability] = [:]

    private var resource: String?
    private var task: Task<Void, Never>?
    private var refreshing = false

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
            guard self.resource == resource else { return }
            state = .failed
            return
        }
        guard self.resource == resource else { return }
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
        availabilityByResource[resource] = .available
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
        guard self.resource == resource else { return }
        switch CompanionActivityParser.parse(shopStatus: reply.status, shopBody: reply.body,
                                             eventBodies: eventBodies) {
        case .unavailable:
            availability = .unavailable
            state = .idle
        case .failed:
            state = .failed
        case .ready(let agents):
            state = .ready(agents)
            lastRead = Date()
        }
    }

    func clearSummary(_ resource: String) {
        summaries[resource] = nil
        summaryFetched[resource] = nil
    }

    func loadSummaries(resources: [String]) async {
        for resource in resources where !summaryLoading.contains(resource) {
            if let fetched = summaryFetched[resource],
               Date().timeIntervalSince(fetched) < 60,
               summaries[resource] != nil { continue }
            summaryLoading.insert(resource)
            guard let reply = await CompanionApprovalsMonitor.shared.fetch(path: Self.shopPath(resource)) else {
                summaries[resource] = .failed
                summaryFetched[resource] = nil
                summaryLoading.remove(resource)
                continue
            }
            if reply.status == 404 {
                summaries[resource] = .unavailable
                summaryFetched[resource] = Date()
                summaryLoading.remove(resource)
                continue
            }
            guard reply.status == 200, let data = reply.body.data(using: .utf8),
                  let shop = try? JSONDecoder().decode(CompanionShopActivity.self, from: data) else {
                summaries[resource] = .failed
                summaryFetched[resource] = nil
                summaryLoading.remove(resource)
                continue
            }
            summaries[resource] = .ready(
                agents: shop.tabs.count,
                working: shop.tabs.filter { $0.state == "working" }.count)
            summaryFetched[resource] = Date()
            summaryLoading.remove(resource)
        }
    }

    static func shopPath(_ resource: String) -> String {
        "/api/oo/shops/\(escape(resource))/agents/activity"
    }

    static func agentPath(resource: String, agent: String) -> String {
        "/api/oo/shops/\(escape(resource))/agents/\(escape(agent))/activity"
    }

    static func agentPagePath(resource: String, agent: String) -> String {
        activityPath("/companion/app/\(escape(resource))/people/\(escape(agent))", panel: agent)
    }

    static func shopPagePath(resource: String) -> String {
        activityPath("/companion/app/\(escape(resource))/messages/management", panel: "ollie")
    }

    private static func activityPath(_ path: String, panel: String) -> String {
        var components = URLComponents(string: path)
        components?.queryItems = [URLQueryItem(name: "activityPanel", value: panel)]
        return components?.string ?? path
    }

    nonisolated static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
