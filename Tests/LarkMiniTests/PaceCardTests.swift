import XCTest
@testable import LarkMini

final class PaceCardTests: XCTestCase {
    func testApprovedLabelsUseCurrenciesAndPortfolioDates() throws {
        let body = #"{"month":{"start":"2026-11-01","day":9,"days_in_month":30},"shops":[{"resource":"shop","name":"Shop","day":{"date":"2026-11-07"},"gmv":{"mtd":1200,"currency":"USD","target_currency":"GBP","goal":55000,"expected_by_today":16700,"gap":-15500,"progress_pct":2,"pace_status":"behind"}}]}"#
        let pace = try XCTUnwrap(CompanionPace.parse(body)?.shops["shop"])
        let labels = CompanionPaceLabels(pace: pace)
        XCTAssertEqual(labels.sold, "$1.2k")
        XCTAssertEqual(labels.goal, "2% of £55.0k goal")
        XCTAssertEqual(labels.expected, "today · should be $16.7k")
        XCTAssertEqual(labels.scale?.start, "1 Nov")
        XCTAssertEqual(labels.scale?.end, "30 Nov")
        XCTAssertEqual(labels.footer, "Day 9 of 30 · numbers to Saturday")
        XCTAssertEqual(OlliePacePill.make(pace)?.text, "$15.5k behind")
        XCTAssertEqual(OlliePacePill.ahead("$4.1k").text, "$4.1k ahead")
        XCTAssertEqual(OlliePacePill.noData.text, "No sales data yet")
        let noDate = try XCTUnwrap(CompanionPace.parse(body.replacingOccurrences(of: "\"date\":\"2026-11-07\"", with: "\"date\":null"))?.shops["shop"])
        XCTAssertEqual(CompanionPaceLabels(pace: noDate).footer, "Day 9 of 30")
        let leap = try XCTUnwrap(CompanionPace.parse(body.replacingOccurrences(of: "2026-11-01", with: "2028-02-01").replacingOccurrences(of: "\"days_in_month\":30", with: "\"days_in_month\":29"))?.shops["shop"])
        XCTAssertEqual(CompanionPaceLabels(pace: leap).scale?.end, "29 Feb")
    }
}
