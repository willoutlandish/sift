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
}
