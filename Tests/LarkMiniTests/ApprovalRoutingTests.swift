import XCTest
@testable import LarkMini

final class ApprovalRoutingTests: XCTestCase {
    func testShopBatchAndSupportedBuyerFilter() {
        XCTAssertEqual(OllieApprovalBatch.clickPath(resources: ["samsonite", "samsonite"], kind: "buyer_reply_needed"), "/companion/app/samsonite/approvals?type=buyer_reply")
        XCTAssertEqual(OllieApprovalBatch.clickPath(resources: ["one"], kind: "budget"), "/companion/app/one/approvals")
        XCTAssertEqual(OllieApprovalBatch.clickPath(resources: ["one", "two"], kind: "budget"), "/companion/app/approvals")
    }
    func testServerItemLinkPreservesPathAndQuery() {
        let base = URL(string: "https://example.com")!
        let link = "/companion/app/ajmal/approvals?item=budget%3Aone"
        XCTAssertEqual(CompanionApprovalEligibility.safeHref(link), link)
        XCTAssertEqual(CompanionConfig.cliTargetURL(base: base, path: link)?.absoluteString, "https://example.com" + link)
    }
}
