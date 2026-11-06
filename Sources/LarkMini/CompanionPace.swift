import Foundation

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
    static let path = "/api/oo/control-room/shops"

    static func parse(_ body: String) -> [String: CompanionShopPace]? {
        guard let data = body.data(using: .utf8),
              let list = try? JSONDecoder().decode(PaceList.self, from: data) else { return nil }
        return Dictionary(uniqueKeysWithValues: list.shops.map { shop in
            let gmv = shop.gmv
            return (shop.resource, CompanionShopPace(
                resource: shop.resource,
                name: shop.name,
                currency: gmv.currency,
                mtd: gmv.mtd,
                goal: gmv.goal,
                expectedByToday: gmv.expected_by_today,
                gap: gmv.gap,
                progressPct: gmv.progress_pct,
                paceStatus: gmv.pace_status ?? "no_data",
                basis: gmv.basis))
        })
    }

    private struct PaceList: Decodable {
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
            let resource: String
            let name: String
            let gmv: GMV
        }
        let shops: [Shop]
    }
}
