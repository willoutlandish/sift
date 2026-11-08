import Foundation

enum ApprovalNotificationMode: String, CaseIterable, Identifiable {
    case urgentMine, allMine, urgentAll, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .urgentMine: return "Urgent things waiting on me"
        case .allMine: return "Everything waiting on me"
        case .urgentAll: return "Urgent things in all my shops"
        case .off: return "Off"
        }
    }
    static func options(canSeeAll: Bool) -> [Self] { allCases.filter { $0 != .urgentAll || canSeeAll } }
}

struct ApprovalNotificationPolicy {
    struct Plan {
        let seen: Set<String>
        let badge: Int
        let singles: [CompanionApproval]
        let summaryCount: Int
    }
    var lastSent: [String: Date] = [:]
    static let interval: TimeInterval = 600
    static func qualifies(_ item: CompanionApproval, mode: ApprovalNotificationMode, canSeeAll: Bool) -> Bool {
        // SharedApprovalsList uses the server's Mine decision, which resolves viewer and seat ownership.
        switch mode == .urgentAll && !canSeeAll ? .urgentMine : mode {
        case .urgentMine: return item.mine && (item.band == "now" || item.riskReason == "money")
        case .allMine: return item.mine
        case .urgentAll: return item.band == "now"
        case .off: return false
        }
    }
    static func badge(_ items: [CompanionApproval], mode: ApprovalNotificationMode, canSeeAll: Bool) -> Int {
        Set(items.filter { qualifies($0, mode: mode, canSeeAll: canSeeAll) }.map(\.id)).count
    }
    mutating func plan(items: [CompanionApproval], seen: Set<String>, mode: ApprovalNotificationMode,
                       canSeeAll: Bool, deliveryEnabled: Bool, now: Date) -> Plan {
        let qualified = items.filter { Self.qualifies($0, mode: mode, canSeeAll: canSeeAll) }
        let fresh = qualified.filter { !seen.contains($0.id) }
        var singles: [CompanionApproval] = []
        var summary = 0
        if deliveryEnabled {
            if fresh.count > 3 {
                // A summary is a separate rate-limit bucket from individual shops.
                if maySend("summary", now: now) { summary = fresh.count; lastSent["summary"] = now }
            } else {
                for item in fresh {
                    let key = "shop:" + (item.resource ?? "unknown")
                    if maySend(key, now: now) { singles.append(item); lastSent[key] = now }
                }
            }
        }
        return Plan(seen: seen.union(items.map(\.id)), badge: Self.badge(items, mode: mode, canSeeAll: canSeeAll),
                    singles: singles, summaryCount: summary)
    }
    private func maySend(_ key: String, now: Date) -> Bool {
        lastSent[key].map { now.timeIntervalSince($0) >= Self.interval } ?? true
    }
}
