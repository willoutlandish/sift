import Foundation

struct CompanionPaceAgent: Equatable {
    let role: String
    let on: Bool
}

struct CompanionShopPace: Equatable {
    let resource: String
    let name: String
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

    init(resource: String, name: String, currency: String?, mtd: Double?, goal: Double?,
         expectedByToday: Double?, gap: Double?, progressPct: Double?, paceStatus: String,
         basis: String?, metricsThrough: String? = nil, needsYouTotal: Int? = nil,
         agents: [CompanionPaceAgent] = []) {
        self.resource = resource
        self.name = name
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
}

struct CompanionPacePayload: Equatable {
    let shops: [String: CompanionShopPace]
    let totals: CompanionPaceTotals?
    let metricsThrough: String?
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

enum CompanionPaceTone: Equatable {
    case green
    case red
    case grey
}

struct CompanionPaceBarModel: Equatable {
    let actual: Double?
    let goal: Double?
    let expected: Double?
    let progressPct: Double?
    let currency: String?
    let status: String
    let actualFraction: Double
    let expectedFraction: Double?
    let text: String
    let statusLabel: String
    let tone: CompanionPaceTone

    init(_ pace: CompanionShopPace) {
        actual = pace.mtd
        goal = pace.goal
        expected = pace.expectedByToday
        progressPct = pace.progressPct
        currency = pace.currency
        status = pace.paceStatus

        let goalValue = pace.goal ?? 0
        actualFraction = goalValue > 0 ? Self.clamp((pace.mtd ?? 0) / goalValue) : 0
        expectedFraction = goalValue > 0 ? pace.expectedByToday.map { Self.clamp($0 / goalValue) } : nil

        switch pace.paceStatus {
        case "on_track": statusLabel = "On track"; tone = .green
        case "ahead": statusLabel = "Ahead"; tone = .green
        case "behind": statusLabel = "Behind"; tone = .red
        case "too_early": statusLabel = "Too early"; tone = .grey
        case "no_target": statusLabel = "No target"; tone = .grey
        default: statusLabel = "No data"; tone = .grey
        }

        if pace.goal == nil || goalValue <= 0 {
            text = "No target"
        } else if pace.mtd == nil || pace.expectedByToday == nil {
            text = "No data"
        } else {
            let actualText = Self.money(pace.mtd ?? 0, currency: pace.currency)
            let expectedText = Self.money(pace.expectedByToday ?? 0, currency: pace.currency)
            let percent = pace.progressPct.map { Int($0.rounded()) }
            text = percent.map { "\(actualText) of \(expectedText) expected by today (\($0)%)" }
                ?? "\(actualText) of \(expectedText) expected by today"
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func money(_ value: Double, currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = currency == nil ? .decimal : .currency
        if let currency { formatter.currencyCode = currency }
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }
}

enum CompanionPace {
    static let path = "/api/oo/portfolio"

    static func matches(shopResource: String, shopName: String, pace: CompanionShopPace) -> Bool {
        shopResource.caseInsensitiveCompare(pace.resource) == .orderedSame || shopName == pace.name
    }

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
        guard let date = parser.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM"
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
        for shop in list.shops {
            guard let resource = shop.resource, let name = shop.name, let gmv = shop.gmv,
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
                metricsThrough: shop.metrics_through,
                needsYouTotal: shop.needs_you?.total,
                agents: (shop.agents ?? []).map {
                    CompanionPaceAgent(role: $0.role ?? "agent", on: $0.on ?? false)
                })
            if shops[resource] == nil { shops[resource] = pace }
        }
        let totals = list.totals.map { totals in
            CompanionPaceTotals(
                byCurrency: (totals.gmv_by_currency ?? []).map {
                    CompanionPaceCurrencyTotal(currency: $0.currency, mtd: $0.mtd, goal: $0.goal)
                },
                behind: totals.behind,
                unavailableShops: totals.gmv_unavailable_shops,
                elapsedPct: list.month?.elapsed_pct)
        }
        let metricsThrough = list.shops.compactMap(\.metrics_through).first
        return CompanionPacePayload(shops: shops, totals: totals, metricsThrough: metricsThrough)
    }

    private struct Portfolio: Decodable {
        struct Month: Decodable {
            let elapsed_pct: Double?
        }
        struct Shop: Decodable {
            struct GMV: Decodable {
                let mtd: Double?
                let currency: String?
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
            let gmv: GMV?
            let metrics_through: String?
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
        let shops: [Shop]
        let totals: Totals?
        let month: Month?
    }
}
