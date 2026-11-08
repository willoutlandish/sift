import XCTest
@testable import LarkMini

final class TodayQATests: XCTestCase {
    func testClassificationFilteringAndResourceDeduplication() throws {
        let payload = try XCTUnwrap(CompanionPace.parse(#"{"viewer":{"kind":"staff","default_scope":"mine"},"shops":[{"resource":"a","name":"Adobe","gmv":{"mtd":null,"goal":100,"progress_pct":0,"pace_status":"no_data"}},{"resource":"a","name":"Duplicate","gmv":{"mtd":10}},{"resource":"b","name":"No target","gmv":{"mtd":null,"pace_status":"no_target"}},{"resource":"outside","name":"Not mine","scope":{"mine":false},"gmv":{"mtd":2}}]}"#))
        XCTAssertEqual(payload.shops.count, 2)
        let model = OllieTodayModel(pace: payload.shops, paceState: .available, snapshot: nil, activity: ["a": .ready(agents: 1, working: 1)])
        XCTAssertEqual(model.summary, "1 with targets · 0 on pace · 0 behind · 1 without targets · 1 without sales data · 1 agent working")
        XCTAssertEqual(model.filteredShops("ADO").map(\.resource), ["a"])
        XCTAssertEqual(model.filteredShops("  ").count, 2)
        XCTAssertFalse(CompanionPaceLabels(pace: payload.shops["a"]!).goal.contains("0%"))
    }
    func testAllShopTargetSubsetIsExplicit() throws {
        let payload = try XCTUnwrap(CompanionPace.parse(#"{"shops":[{"resource":"a","name":"A","gmv":{"currency":"USD","mtd":100,"goal":1000,"progress_pct":10}},{"resource":"b","name":"B","gmv":{"currency":"USD","mtd":900}},{"resource":"c","name":"C","gmv":{"currency":"GBP","mtd":30}}]}"#))
        let cards = OllieTodayModel(pace: payload.shops, paceState: .available, snapshot: nil, activity: [:]).allProgress
        XCTAssertEqual(cards[0].pace.mtd, 1000)
        XCTAssertEqual(cards[0].pace.progressPct, 10)
        XCTAssertEqual(cards[0].targetShopCount, 1)
        XCTAssertTrue(cards[1].label.hasPrefix("Also"))
    }
}
