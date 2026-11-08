import XCTest
@testable import LarkMini

final class CompanionWindowTitleTests: XCTestCase {
    func testResourceTitleAndFallback() {
        let names = ["crocs": "CROCS", "shop one": "Shop One"]
        XCTAssertEqual(CompanionWindowTitle.make(path: "/companion/app/crocs/approvals", names: names), "Ollie · CROCS")
        XCTAssertEqual(CompanionWindowTitle.make(path: "/companion/app/shop%20one", names: names), "Ollie · Shop One")
        for path in ["/", "/companion/app", "/companion/app/approvals", "/companion/application/crocs", "/companion/app/unknown"] {
            XCTAssertEqual(CompanionWindowTitle.make(path: path, names: names), "Ollie")
        }
    }
    func testPortfolioKeepsNamesWithoutSalesData() throws {
        let payload = try XCTUnwrap(CompanionPace.parse(#"{"shops":[{"resource":"one","name":"One"}]}"#))
        XCTAssertEqual(payload.shopNames, ["one": "One"])
        XCTAssertEqual(CompanionWindowTitle.make(path: "/companion/app/one/chat", names: payload.shopNames), "Ollie · One")
    }
}
