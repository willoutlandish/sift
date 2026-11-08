import Foundation

struct CompanionPaceAgent: Equatable {
    let role: String
    let on: Bool
}

struct CompanionPaceMonth: Equatable {
    let start: String?
    let day: Int?
    let daysInMonth: Int?
}

struct CompanionShopPace: Equatable {
    let resource: String
    let name: String
    let targetCurrency: String?
    let currency: String?
    let mtd: Double?
    let goal: Double?
    let expectedByToday: Double?
    let gap: Double?
    let progressPct: Double?
    let paceStatus: String
    let basis: String?
    let metricsThrough: String?
    let needsYouTotal: Int?
    let agents: [CompanionPaceAgent]
    let month: CompanionPaceMonth?

    init(resource: String, name: String, currency: String?, mtd: Double?, goal: Double?,
         expectedByToday: Double?, gap: Double?, progressPct: Double?, paceStatus: String,
         basis: String?, metricsThrough: String? = nil, needsYouTotal: Int? = nil,
         agents: [CompanionPaceAgent] = [], targetCurrency: String? = nil, month: CompanionPaceMonth? = nil) {
        self.resource = resource
        self.name = name
        self.targetCurrency = targetCurrency
        self.currency = currency
        self.mtd = mtd
        self.goal = goal
        self.expectedByToday = expectedByToday
        self.gap = gap
        self.progressPct = progressPct
        self.paceStatus = paceStatus
        self.basis = basis
        self.metricsThrough = metricsThrough
        self.needsYouTotal = needsYouTotal
        self.agents = agents
        self.month = month
    }
}

struct CompanionPaceCurrencyTotal: Equatable {
    let currency: String?
    let mtd: Double?
    let goal: Double?
}

struct CompanionPaceTotals: Equatable {
    let byCurrency: [CompanionPaceCurrencyTotal]
    let behind: Int?
    let unavailableShops: Int?
    let elapsedPct: Double?
    var monthLeft: String? = nil
    var month: CompanionPaceMonth? = nil
}

struct CompanionPacePayload: Equatable {
    let shops: [String: CompanionShopPace]
    let totals: CompanionPaceTotals?
    let metricsThrough: String?
    var shopNames: [String: String] = [:]
    var canSeeAllShops = false
}

enum CompanionPaceState: Equatable {
    case unknown
    case available
    case hidden
    case failed

    static func from(status: Int) -> CompanionPaceState {
        switch status {
        case 200: return .available
        case 403, 404: return .hidden
        default: return .failed
        }
    }

    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .available: return "available"
        case .hidden: return "hidden"
        case .failed: return "failed"
        }
    }
}

struct CompanionPaceBarModel: Equatable {
    let actualFraction: Double
    let expectedFraction: Double?

    init(_ pace: CompanionShopPace) {
        actualFraction = min(1, max(0, (pace.progressPct ?? 0) / 100))
        expectedFraction = (pace.goal ?? 0) > 0 ? pace.expectedByToday.map { min(1, max(0, $0 / pace.goal!)) } : nil
    }
}

enum CompanionPace {
    static let path = "/api/oo/portfolio"

    static func compactMoney(_ value: Double?, currency: String?, signed: Bool = false) -> String {
        guard let value else { return "" }
        let sign = value < 0 ? "−" : (signed ? "+" : "")
        let magnitude = abs(value)
        let number: String
        if magnitude >= 1_000_000 {
            number = String(format: "%.1fm", magnitude / 1_000_000)
        } else if magnitude >= 1_000 {
            number = String(format: "%.1fk", magnitude / 1_000)
        } else {
            number = String(format: "%.0f", magnitude)
        }
        return sign + currencySymbol(currency) + number
    }

    static func money(_ value: Double?, currency: String?) -> String {
        guard let value else { return "" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = currency == nil ? .decimal : .currency
        if let currency { formatter.currencyCode = currency }
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }

    static func metricsText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    static func currencySymbol(_ currency: String?) -> String {
        guard let currency else { return "" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.currencySymbol ?? ""
    }

    static func parse(_ body: String) -> CompanionPacePayload? {
        guard let data = body.data(using: .utf8),
              let list = try? JSONDecoder().decode(Portfolio.self, from: data) else { return nil }
        var shops: [String: CompanionShopPace] = [:]
        // Mirrors home/shops-dashboard.ts shopsInScope (including its legacy fallback).
        let scope = list.viewer?.default_scope ?? "all"
        let scoped = list.shops.filter {
            scope == "all" || list.viewer?.kind == "client" || ($0.scope?[scope] ?? true)
        }
        for shop in scoped {
            guard let resource = shop.resource, let name = shop.displayName, let gmv = shop.gmv,
                  !resource.isEmpty, !name.isEmpty else { continue }
            let pace = CompanionShopPace(
                resource: resource,
                name: name,
                currency: gmv.currency,
                mtd: gmv.mtd,
                goal: gmv.goal,
                expectedByToday: gmv.expected_by_today,
                gap: gmv.gap,
                progressPct: gmv.progress_pct,
                paceStatus: gmv.pace_status ?? "no_data",
                basis: gmv.basis,
                metricsThrough: shop.day?.date,
                needsYouTotal: shop.needs_you?.total,
                agents: (shop.agents ?? []).map {
                    CompanionPaceAgent(role: $0.role ?? "agent", on: $0.on ?? false)
                }, targetCurrency: gmv.target_currency, month: list.month?.model)
            if shops[resource] == nil { shops[resource] = pace }
        }
        let totals = list.month.map { _ in list.totals }.map { totals in
            CompanionPaceTotals(
                byCurrency: (totals?.gmv_by_currency ?? []).map {
                    CompanionPaceCurrencyTotal(currency: $0.currency, mtd: $0.mtd, goal: $0.goal)
                },
                behind: totals?.behind,
                unavailableShops: totals?.gmv_unavailable_shops,
                elapsedPct: list.month?.elapsed_pct, monthLeft: list.month?.left, month: list.month?.model)
        }
        let metricsThrough = scoped.compactMap { $0.day?.date }.max()
        var names: [String: String] = [:]
        for shop in list.shops {
            if let resource = shop.resource, let name = shop.displayName, !resource.isEmpty, !name.isEmpty { names[resource] = name }
        }
        return CompanionPacePayload(shops: shops, totals: totals, metricsThrough: metricsThrough, shopNames: names, canSeeAllShops: list.viewer?.kind == "staff" && list.viewer?.scopes?["all"] != nil)
    }

    private struct Portfolio: Decodable {
        struct Month: Decodable {
            let start: String?
            var model: CompanionPaceMonth { CompanionPaceMonth(start: start, day: day, daysInMonth: days_in_month) }
            let elapsed_pct: Double?
            let days_left: Int?
            let days_in_month: Int?
            let day: Int?
            var left: String? {
                guard let days = days_left ?? days_in_month.flatMap({ total in day.map { total - $0 } }) else { return nil }
                return days <= 0 ? "The month is over" : (days == 1 ? "1 day left" : "\(days) days left")
            }
        }
        struct Shop: Decodable {
            struct GMV: Decodable {
                let mtd: Double?
                let currency: String?
                let target_currency: String?
                let goal: Double?
                let expected_by_today: Double?
                let gap: Double?
                let progress_pct: Double?
                let pace_status: String?
                let basis: String?
            }
            struct NeedsYou: Decodable { let total: Int? }
            struct Agent: Decodable { let role: String?; let on: Bool? }
            let resource: String?
            let name: String?
            let display_name: String?
            var displayName: String? { display_name ?? name }
            let gmv: GMV?
            struct Day: Decodable { let date: String? }
            let day: Day?
            let scope: [String: Bool]?
            let needs_you: NeedsYou?
            let agents: [Agent]?
        }
        struct CurrencyTotal: Decodable {
            let currency: String?
            let mtd: Double?
            let goal: Double?
        }
        struct Totals: Decodable {
            let gmv_by_currency: [CurrencyTotal]?
            let behind: Int?
            let gmv_unavailable_shops: Int?
        }
        struct Viewer: Decodable { let kind: String?; let default_scope: String?; let scopes: [String: Int]? }
        let viewer: Viewer?
        let shops: [Shop]
        let totals: Totals?
        let month: Month?
    }
}
