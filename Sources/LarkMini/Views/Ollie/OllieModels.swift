import Foundation

enum OlliePacePill: Equatable {
    case behind(String)
    case onTrack
    case ahead(String)
    case tooEarly
    case noTarget
    case noData

    var text: String {
        switch self {
        case .behind(let amount): return "Behind " + amount
        case .onTrack: return "On track"
        case .ahead(let amount): return "Ahead " + amount
        case .tooEarly: return "Too early"
        case .noTarget: return "No target"
        case .noData: return "No sales data"
        }
    }

    static func make(_ pace: CompanionShopPace?) -> OlliePacePill? {
        guard let pace else { return nil }
        switch pace.paceStatus {
        case "behind":
            return .behind(CompanionPace.compactMoney(pace.gap, currency: pace.currency, signed: true))
        case "on_track":
            return .onTrack
        case "ahead":
            return .ahead(CompanionPace.compactMoney(pace.gap, currency: pace.currency, signed: true))
        case "too_early":
            return .tooEarly
        case "no_target":
            return .noTarget
        default:
            return .noData
        }
    }

    var tone: OllieTone {
        switch self {
        case .behind: return .red
        case .onTrack: return .green
        case .ahead: return .lime
        case .tooEarly, .noTarget, .noData: return .muted
        }
    }
}

struct OllieTodayShop: Identifiable, Equatable {
    let resource: String
    let name: String
    let pace: CompanionShopPace?
    let pending: Int?
    let activity: CompanionShopActivitySummary?

    var id: String { resource }
    var bar: CompanionPaceBarModel? { pace.map(CompanionPaceBarModel.init) }

    var pill: OlliePacePill? { OlliePacePill.make(pace) }
    var portfolioWorking: Int? { pace?.agents.filter(\.on).count }

    var isPaceBehind: Bool { pace?.paceStatus == "behind" }
    var isOnTrack: Bool { pace?.paceStatus == "on_track" }
    var isAhead: Bool { pace?.paceStatus == "ahead" }
}

struct OllieAllShopProgress: Identifiable, Equatable {
    let currency: String?
    let pace: CompanionShopPace

    var id: String { currency ?? "all" }
    var label: String { currency.map { "All shops · \($0)" } ?? "All shops" }
    var pill: OlliePacePill? { OlliePacePill.make(pace) }
    var bar: CompanionPaceBarModel { CompanionPaceBarModel(pace) }
}

struct OllieTodayModel: Equatable {
    let shops: [OllieTodayShop]
    let summary: String
    let onPace: Int?
    let totalPace: Int?
    let behind: Int?
    let working: Int?
    let needYou: Int?
    let paceAvailable: Bool
    let allProgress: [OllieAllShopProgress]

    init(pace: [String: CompanionShopPace], paceState: CompanionPaceState,
         snapshot: CompanionTodoSnapshot?, activity: [String: CompanionShopActivitySummary],
         totals: CompanionPaceTotals? = nil) {
        let paceAvailable = paceState == .available
        let approvalsAvailable = snapshot != nil
        var shops: [OllieTodayShop] = []

        if paceAvailable {
            for paceShop in pace.values {
                let approvalShop = snapshot?.shops.first {
                    $0.resource.caseInsensitiveCompare(paceShop.resource) == .orderedSame || $0.name == paceShop.name
                }
                shops.append(OllieTodayShop(
                    resource: paceShop.resource,
                    name: paceShop.name,
                    pace: paceShop,
                    pending: approvalsAvailable ? (approvalShop?.pending ?? paceShop.needsYouTotal) : paceShop.needsYouTotal,
                    activity: activity[paceShop.resource]))
            }
        }

        if let snapshot {
            for approvalShop in snapshot.shops where !shops.contains(where: {
                $0.resource.caseInsensitiveCompare(approvalShop.resource) == .orderedSame || $0.name == approvalShop.name
            }) {
                shops.append(OllieTodayShop(
                    resource: approvalShop.resource,
                    name: approvalShop.name,
                    pace: nil,
                    pending: approvalShop.pending,
                    activity: activity[approvalShop.resource]))
            }
        }

        shops.sort { left, right in
            let leftRank = Self.rank(left.pace?.paceStatus)
            let rightRank = Self.rank(right.pace?.paceStatus)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        let paceShops = shops.compactMap(\.pace)
        let onPace = paceAvailable ? paceShops.filter { ["on_track", "ahead"].contains($0.paceStatus) }.count : nil
        let totalPace = paceAvailable ? paceShops.count : nil
        let behind = paceAvailable ? paceShops.filter { $0.paceStatus == "behind" }.count : nil
        let working: Int? = {
            let ready = activity.values.compactMap { summary -> Int? in
                if case .ready(_, let working) = summary { return working }
                return nil
            }
            if !ready.isEmpty { return ready.reduce(0, +) }
            let agents = paceShops.flatMap(\.agents)
            return agents.isEmpty ? nil : agents.filter(\.on).count
        }()
        let needYou = snapshot?.total ?? paceShops.compactMap(\.needsYouTotal).reduce(nil) { partial, value in
            (partial ?? 0) + value
        }

        var parts: [String] = []
        let unavailable = totals?.unavailableShops
        if paceAvailable, !shops.isEmpty,
           (unavailable.map { $0 >= shops.count } ?? !paceShops.contains(where: { $0.mtd != nil })) {
            let noun = shops.count == 1 ? "shop" : "shops"
            parts.append("No sales data yet for \(shops.count) \(noun)")
        } else if let onPace, let totalPace, let behind {
            parts.append("\(onPace) of \(totalPace) shops on pace")
            parts.append("\(totals?.behind ?? behind) behind")
            if let unavailable, unavailable > 0 {
                parts.append("\(unavailable) without sales data")
            }
        }
        if let working { parts.append("\(working) agents working") }
        if let needYou { parts.append("\(needYou) need you") }

        self.shops = shops
        self.summary = parts.joined(separator: " · ")
        self.onPace = onPace
        self.totalPace = totalPace
        self.behind = behind
        self.working = working
        self.needYou = needYou
        self.paceAvailable = paceAvailable
        self.allProgress = paceAvailable ? Self.allShopProgress(
            from: Array(pace.values), totals: totals,
            metricsThrough: pace.values.compactMap(\.metricsThrough).first) : []
    }

    private static func allShopProgress(from shops: [CompanionShopPace],
                                        totals: CompanionPaceTotals?,
                                        metricsThrough: String?) -> [OllieAllShopProgress] {
        if let totals, !totals.byCurrency.isEmpty {
            return totals.byCurrency.map { total in
                // Portfolio totals omit expected_by_today; the tick is the month's elapsed percentage of goal.
                let expected = (total.goal ?? 0) > 0
                    ? total.goal! * ((totals.elapsedPct ?? 0) / 100) : nil
                let gap = (total.mtd != nil && expected != nil) ? total.mtd! - expected! : nil
                let progress = (total.mtd != nil && (total.goal ?? 0) > 0)
                    ? total.mtd! / total.goal! * 100 : nil
                let status: String
                if total.goal == nil || (total.goal ?? 0) <= 0 {
                    status = "no_target"
                } else if total.mtd == nil || expected == nil {
                    status = "no_data"
                } else if let gap, gap < 0 {
                    status = "behind"
                } else if total.mtd! >= total.goal! {
                    status = "ahead"
                } else {
                    status = "on_track"
                }
                return OllieAllShopProgress(
                    currency: total.currency,
                    pace: CompanionShopPace(resource: "all-\(total.currency ?? "none")", name: "All shops",
                                            currency: total.currency, mtd: total.mtd, goal: total.goal,
                                            expectedByToday: expected, gap: gap,
                                            progressPct: progress, paceStatus: status, basis: "total",
                                            metricsThrough: metricsThrough))
            }.sorted { ($0.currency ?? "") < ($1.currency ?? "") }
        }
        let grouped = Dictionary(grouping: shops, by: \.currency)
        return grouped.map { currency, group in
            let mtd = group.compactMap(\.mtd)
            let goals = group.compactMap(\.goal)
            let expected = group.compactMap(\.expectedByToday)
            let gaps = group.compactMap(\.gap)
            let actual = mtd.isEmpty ? nil : mtd.reduce(0, +)
            let goal = goals.isEmpty ? nil : goals.reduce(0, +)
            let expectedByToday = expected.isEmpty ? nil : expected.reduce(0, +)
            let gap = gaps.isEmpty ? nil : gaps.reduce(0, +)
            let status: String
            if goal == nil || (goal ?? 0) <= 0 {
                status = "no_target"
            } else if actual == nil || expectedByToday == nil {
                status = "no_data"
            } else if let gap, gap < 0 {
                status = "behind"
            } else if let actual, let goal, actual >= goal {
                status = "ahead"
            } else {
                status = "on_track"
            }
            let progress = (actual != nil && (goal ?? 0) > 0) ? (actual! / goal! * 100) : nil
            return OllieAllShopProgress(
                currency: currency,
                pace: CompanionShopPace(resource: "all-\(currency ?? "none")", name: "All shops",
                                        currency: currency, mtd: actual, goal: goal,
                                        expectedByToday: expectedByToday, gap: gap,
                                        progressPct: progress, paceStatus: status, basis: "total"))
        }.sorted { ($0.currency ?? "") < ($1.currency ?? "") }
    }

    private static func rank(_ status: String?) -> Int {
        switch status {
        case "behind": return 0
        case "on_track": return 1
        case "ahead": return 2
        case "too_early", "no_target", "no_data": return 3
        default: return 4
        }
    }
}

struct OllieActivityNode: Equatable {
    let agent: CompanionActivityAgent

    var title: String {
        let role = agent.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !role.isEmpty else { return agent.name }
        return role.replacingOccurrences(of: "-", with: " ").lowercased()
    }

    var tone: OllieTone {
        switch agent.state {
        case "working": return .blue
        case "waiting": return .amber
        case "failed": return .red
        case "idle": return .green
        case "paused", "off": return .muted
        default: return .muted
        }
    }

    var pill: String {
        switch agent.state {
        case "working", "waiting", "failed", "idle", "paused", "off":
            return agent.state.uppercased()
        default:
            return agent.state.isEmpty ? "IDLE" : agent.state.uppercased()
        }
    }

    var countsText: String? {
        var parts: [String] = []
        if let runs = agent.runs48h { parts.append("\(runs) runs / 48h") }
        if let ok = agent.ok48h { parts.append("\(ok) clean") }
        if let partial = agent.partial48h { parts.append("\(partial) partial") }
        if let failed = agent.failed48h { parts.append("\(failed) failed") }
        if let next = agent.nextCheckAt, !CompanionActivityFormat.until(next).isEmpty {
            parts.append("next check \(CompanionActivityFormat.until(next))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum OllieActivityModel {
    static func summary(agents: [CompanionActivityAgent], lastRead: Date?, now: Date = Date()) -> String {
        let working = agents.filter { $0.state == "working" }.count
        var parts = ["\(agents.count) agents", "\(working) working"]
        if let lastRead {
            let seconds = max(0, Int(now.timeIntervalSince(lastRead)))
            let ago = seconds < 60 ? "0m" : CompanionTodos.ageText(seconds)
            parts.append("read \(ago) ago")
        }
        return parts.joined(separator: " · ")
    }
}

struct OllieApprovalCategory: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key }
}

struct OllieApprovalBatch: Identifiable, Equatable {
    let source: String
    let kind: String
    let label: String
    let items: [CompanionTodoItem]
    var id: String { "\(source):\(kind)" }
    var count: Int { items.count }
}

struct OllieApprovalsModel: Equatable {
    let shopName: String?
    let totalHere: Int
    let totalAll: Int
    let categories: [OllieApprovalCategory]
    let doThisFirst: CompanionTodoItem?
    let batches: [OllieApprovalBatch]
    let newer: [CompanionTodoItem]
    let older: [CompanionTodoItem]
    let selectedCategory: String?

    init(snapshot: CompanionTodoSnapshot?, shopResource: String?, category: String? = nil) {
        let shop = shopResource.flatMap { resource in
            snapshot?.shops.first { $0.resource.caseInsensitiveCompare(resource) == .orderedSame }
        }
        let scope = shop?.allItems ?? snapshot?.orderedItems ?? []
        let categories = Dictionary(grouping: scope, by: \.categoryKey)
            .map { key, items in
                OllieApprovalCategory(key: key, label: items.first?.categoryLabel ?? "Other")
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let filtered = category.map { selected in scope.filter { $0.categoryKey == selected } } ?? scope
        let first = filtered.first
        let remaining = Array(filtered.dropFirst())

        var groups: [String: [CompanionTodoItem]] = [:]
        for item in remaining {
            groups["\(item.source):\(item.kind)", default: []].append(item)
        }
        var batches: [OllieApprovalBatch] = []
        var singles: [CompanionTodoItem] = []
        for item in remaining {
            let key = "\(item.source):\(item.kind)"
            guard let group = groups[key] else { continue }
            if group.count > 1 {
                if !batches.contains(where: { $0.id == key }) {
                    let label = item.categoryLabel
                    batches.append(OllieApprovalBatch(source: item.source, kind: item.kind,
                                                       label: Self.batchLabel(label, count: group.count),
                                                       items: group))
                }
            } else {
                singles.append(item)
            }
        }

        self.shopName = shop?.name
        self.totalHere = scope.count
        self.totalAll = snapshot?.total ?? scope.count
        self.categories = categories
        self.doThisFirst = first
        self.batches = batches
        self.newer = singles.filter { !$0.isOlder }
        self.older = singles.filter(\.isOlder)
        self.selectedCategory = category
    }

    static func batchLabel(_ label: String, count: Int) -> String {
        let lower = label.lowercased()
        guard count != 1 else { return "\(count) \(lower)" }
        if lower.hasSuffix("s") { return "\(count) \(lower)" }
        if lower.hasSuffix("ch") || lower.hasSuffix("sh") || lower.hasSuffix("x") {
            return "\(count) \(lower)es"
        }
        if lower.hasSuffix("y") {
            return "\(count) \(lower.dropLast())ies"
        }
        return "\(count) \(lower)s"
    }

    static func isOverdue(_ item: CompanionTodoItem, now: Date = Date()) -> Bool {
        guard let expires = item.expiresAt, let date = parse(expires) else { return false }
        return date < now
    }

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
