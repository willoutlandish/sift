import XCTest
@testable import LarkMini

final class PortfolioCorrectnessTests: XCTestCase {
    func testNewestCompleteDayWithinDefaultScopeAndTargetCurrency() throws {
        let json = #"""
        {"viewer":{"kind":"staff","default_scope":"mine"},"shops":[
          {"resource":"a","name":"A","scope":{"mine":true},"day":{"date":"2026-11-05"},"metrics_through":"2026-11-07","gmv":{"currency":"USD","target_currency":"GBP","goal":100}},
          {"resource":"b","name":"B","scope":{"mine":true},"day":{"date":"2026-11-06"},"gmv":{}},
          {"resource":"c","name":"C","scope":{"mine":false},"day":{"date":"2026-11-07"},"gmv":{}}
        ]}
        """#
        let payload = try XCTUnwrap(CompanionPace.parse(json))
        XCTAssertEqual(Set(payload.shops.keys), ["a", "b"])
        XCTAssertEqual(payload.metricsThrough, "2026-11-06")
        XCTAssertEqual(CompanionPace.metricsText(payload.metricsThrough), "Friday")
        XCTAssertEqual(payload.shops["a"]?.targetCurrency, "GBP")
        XCTAssertEqual(payload.shops["a"]?.metricsThrough, "2026-11-05")
        XCTAssertNil(CompanionPace.metricsText("invalid"))
        let client = try XCTUnwrap(CompanionPace.parse(json.replacingOccurrences(of: "staff", with: "client")))
        XCTAssertEqual(client.shops.count, 3)
    }

    func testPrioritySelectionNeverDropsAnUnselectedItem() throws {
        for bands in [["soon", "later"], ["soon", "now"]] {
            let items = try bands.enumerated().map { index, band in
                try JSONDecoder().decode(CompanionApprovalsList.Item.self,
                    from: Data("{\"id\":\"\(index)\",\"kind\":\"\(index)\",\"priority\":{\"band\":\"\(band)\"}}".utf8))
            }
            let list = CompanionApprovalsList(shops: [.init(resource: "a", name: "A",
                services: [.init(role: nil, label: "Agent", items: items)])], order: nil, counts: nil)
            let model = OllieApprovalsModel(snapshot: CompanionTodos.make(from: list), shopResource: nil)
            XCTAssertEqual(model.newer.count + (model.doThisFirst == nil ? 0 : 1), 2)
            XCTAssertEqual(model.doThisFirst?.id, bands.contains("now") ? "1" : nil)
        }
    }
    func testGoalPercentageExcludesUntargetedSales() {
        let targeted = CompanionShopPace(resource: "a", name: "A", currency: "USD", mtd: 50, goal: 100,
            expectedByToday: nil, gap: nil, progressPct: 50, paceStatus: "on_track", basis: nil)
        let untargeted = CompanionShopPace(resource: "b", name: "B", currency: "USD", mtd: 1000, goal: nil,
            expectedByToday: nil, gap: nil, progressPct: nil, paceStatus: "no_target", basis: nil)
        let crossCurrency = CompanionShopPace(resource: "c", name: "C", currency: "USD", mtd: 500, goal: 100,
            expectedByToday: nil, gap: nil, progressPct: nil, paceStatus: "no_data", basis: nil, targetCurrency: "GBP")
        let model = OllieTodayModel(pace: ["a": targeted, "b": untargeted, "c": crossCurrency], paceState: .available,
            snapshot: nil, activity: [:])
        XCTAssertEqual(model.allProgress.first?.pace.mtd, 1550)
        XCTAssertEqual(model.allProgress.first?.pace.progressPct, 50)
        XCTAssertEqual(model.allProgress.first?.pace.goal, 100)
        XCTAssertEqual(model.allProgress.first?.bar.actualFraction, 0.5)
    }

    func testActivityWordsAndBadOutcomes() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(CompanionActivityFormat.ago("1969-12-31T23:57:00Z", now: now), "3 min ago")
        XCTAssertEqual(CompanionActivityFormat.ago("1970-01-01T00:00:20Z", now: now), "just now")
        XCTAssertEqual(CompanionActivityFormat.until("1970-01-01T00:49:00Z", now: now), "in 49 min")
        XCTAssertEqual(CompanionActivityFormat.until("1969-12-31T23:48:00Z", now: now), "12 min late")
        let runs = ["blocked", "timeout", "provider_error", "infra_error"].map { "{\"outcome\":\"\($0)\",\"state\":\"finished\"}" }.joined(separator: ",")
        let parsed = CompanionActivityParser.parse(shopStatus: 200, shopBody: #"{"tabs":[{"agent":"a"}]}"#,
            eventBodies: ["a": "{\"runs\":[\(runs)]}"])
        guard case .ready(let agents) = parsed else { return XCTFail("expected activity") }
        XCTAssertEqual(agents.first?.sparkline, [.failed, .failed, .failed, .failed])
    }

}
