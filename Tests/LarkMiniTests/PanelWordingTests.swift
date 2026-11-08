import XCTest
@testable import LarkMini

final class PanelWordingTests: XCTestCase {
    func testServerLabelsDoNotGetNaivePlurals() {
        XCTAssertEqual(OllieApprovalsModel.batchLabel("Buyer reply needed", count: 2), "2 · Buyer reply needed")
        XCTAssertEqual(OllieActivityModel.waitingLabel("Waiting on a person…"), "Waiting on a person…")
        XCTAssertEqual(OllieActivityModel.waitingLabel("Alex"), "Waiting on: Alex")
    }
}
