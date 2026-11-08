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
        case .behind(let amount): return amount + " behind"
        case .onTrack: return "On pace"
        case .ahead(let amount): return amount + " ahead"
        case .tooEarly: return "Too early to tell"
        case .noTarget: return "No target set"
        case .noData: return "No sales data yet"
        }
    }

    static func make(_ pace: CompanionShopPace?) -> OlliePacePill? {
        guard let pace else { return nil }
        switch pace.paceStatus {
        case "behind":
            let gap = pace.gap.map { abs($0) }
            return .behind(CompanionPace.compactMoney(gap, currency: pace.currency))
        case "on_track":
            return .onTrack
        case "ahead":
            return .ahead(CompanionPace.compactMoney(pace.gap.map { abs($0) }, currency: pace.currency))
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
    var others: [CompanionPaceCurrencyTotal] = []
    var monthLeft: String? = nil

    var id: String { currency ?? "all" }
    var label: String { currency.map { "All shops · \($0)" } ?? "All shops" }
    var pill: OlliePacePill? { pace.gap == nil ? nil : OlliePacePill.make(pace) }
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
                    pending: approvalsAvailable ? (approvalShop?.pending ?? 0) : paceShop.needsYouTotal,
                    activity: activity[paceShop.resource]))
            }
        }

        if let snapshot, !paceAvailable {
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
            let ready = shops.compactMap(\.activity).compactMap { summary -> Int? in
                if case .ready(_, let working) = summary { return working }
                return nil
            }
            if !ready.isEmpty { return ready.reduce(0, +) }
            return nil
        }()
        let needYou = shops.compactMap(\.pending).reduce(nil) { partial, value in
            (partial ?? 0) + value
        }

        var parts: [String] = []
        let unavailable = paceAvailable ? paceShops.filter { $0.mtd == nil }.count : nil
        if paceAvailable, !paceShops.isEmpty,
           (unavailable.map { $0 >= paceShops.count } ?? !paceShops.contains(where: { $0.mtd != nil })) {
            let noun = paceShops.count == 1 ? "shop" : "shops"
            parts.append("\(paceShops.count) \(noun) not selling yet")
        } else if let onPace, let totalPace, let behind {
            parts.append("\(onPace) of \(totalPace) shops on pace")
            parts.append("\(behind) behind")
            if let unavailable, unavailable > 0 {
                parts.append("\(unavailable) without sales data")
            }
        }
        if let working { parts.append("\(working) agents working") }
        else if !paceShops.flatMap(\.agents).isEmpty { parts.append("\(paceShops.flatMap(\.agents).filter(\.on).count) agents on") }
        if let needYou { parts.append("\(needYou) waiting for you") }

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
            metricsThrough: pace.values.compactMap(\.metricsThrough).max()) : []
    }

    private static func allShopProgress(from shops: [CompanionShopPace],
                                        totals: CompanionPaceTotals?,
                                        metricsThrough: String?) -> [OllieAllShopProgress] {
        // Mirrors #19458 home/shops-dashboard.ts dashboardTotals: never combine currencies.
        let grouped = Dictionary(grouping: shops.filter { $0.currency != nil && $0.mtd != nil }, by: { $0.currency! })
        let ordered = grouped.map { currency, group in
            CompanionPaceCurrencyTotal(currency: currency, mtd: group.compactMap(\.mtd).reduce(0, +), goal: nil)
        }.sorted { ($0.mtd ?? 0) > ($1.mtd ?? 0) }
        return ordered.compactMap { total in
            guard let currency = total.currency, let group = grouped[currency] else { return nil }
            let targeted = group.filter { $0.goal != nil && $0.mtd != nil && $0.progressPct != nil }
            let goal = targeted.isEmpty ? nil : targeted.compactMap(\.goal).reduce(0, +)
            let sales = targeted.compactMap(\.mtd).reduce(0, +)
            let pct = (goal ?? 0) != 0 ? (sales / goal! * 100).rounded() : nil
            let expected = goal.flatMap { goal in totals?.elapsedPct.map { goal * $0 / 100 } }
            let gap = expected.map { sales - $0 }
            return OllieAllShopProgress(currency: currency,
                pace: CompanionShopPace(resource: "all", name: "All shops", currency: currency, mtd: total.mtd,
                    goal: goal, expectedByToday: expected, gap: gap, progressPct: pct,
                    paceStatus: gap.map { $0 < 0 ? "behind" : ($0 > 0 ? "ahead" : "on_track") } ?? "",
                    basis: "total", metricsThrough: metricsThrough, targetCurrency: currency, month: totals?.month),
                monthLeft: totals?.monthLeft)
        }
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
        let normalized = role.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return normalized.prefix(1).uppercased() + normalized.dropFirst()
    }

    var tone: OllieTone {
        switch agent.state {
        case "working", "answering": return .blue
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
            return agent.state.capitalized
        default:
            return agent.state.isEmpty ? "Idle" : agent.state.capitalized
        }
    }

    var countsText: String? {
        var parts: [String] = []
        if let runs = agent.runs48h { parts.append("\(runs) runs / 48h") }
        if let ok = agent.ok48h { parts.append("\(ok) clean") }
        if let partial = agent.partial48h { parts.append("\(partial) partial") }
        if let failed = agent.failed48h { parts.append("\(failed) failed") }
        if let next = agent.nextCheckAt, !CompanionActivityFormat.until(next).isEmpty {
            parts.append("Next check \(CompanionActivityFormat.until(next))")
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
    var clickPath: String {
        Self.clickPath(resources: items.map(\.resource), kind: kind)
    }
    static func clickPath(resources: [String], kind: String) -> String {
        let shops = Set(resources.filter { !$0.isEmpty })
        let path = CompanionApprovals.clickPath(resource: shops.count == 1 ? shops.first : nil)
        return shops.count == 1 && ["buyer_reply", "buyer_reply_needed"].contains(kind) ? path + "?type=buyer_reply" : path
    }
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
        let first = filtered.first { $0.priorityBand == "now" }
        let remaining = filtered.filter { $0.id != first?.id }

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

    static func removedWithinDay(_ item: CompanionTodoItem, now: Date = Date()) -> Bool {
        guard let expires = item.expiresAt, let date = CompanionActivityFormat.parse(expires) else { return false }
        return date <= now.addingTimeInterval(86_400)
    }

}
