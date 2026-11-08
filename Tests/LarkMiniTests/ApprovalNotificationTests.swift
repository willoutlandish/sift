import XCTest
@testable import LarkMini

final class ApprovalNotificationTests: XCTestCase {
    private func item(_ id: String = "1", shop: String = "one", mine: Bool = true, band: String? = "now", risk: String? = nil) -> CompanionApproval {
        .init(id: id, label: "Agent", question: "Review", resource: shop, shopName: shop, mine: mine, band: band, riskReason: risk)
    }
    func testQualificationMatrixAndBadge() {
        for mine in [false, true] { for band in ["now", "soon", "later"] { for risk in ["money", "buyer", "creator"] {
            let row = item(mine: mine, band: band, risk: risk)
            XCTAssertEqual(ApprovalNotificationPolicy.qualifies(row, mode: .urgentMine, canSeeAll: true), mine && (band == "now" || risk == "money"))
            XCTAssertEqual(ApprovalNotificationPolicy.qualifies(row, mode: .allMine, canSeeAll: false), mine)
            XCTAssertEqual(ApprovalNotificationPolicy.qualifies(row, mode: .urgentAll, canSeeAll: true), band == "now")
            XCTAssertFalse(ApprovalNotificationPolicy.qualifies(row, mode: .off, canSeeAll: true))
        } } }
        let rows = [item(), item("2", mine: false), item("3", band: "later"), item("4", band: "soon", risk: "money")]
        XCTAssertEqual(ApprovalNotificationPolicy.badge(rows, mode: .urgentMine, canSeeAll: true), 2)
        XCTAssertEqual(ApprovalNotificationPolicy.badge(rows, mode: .off, canSeeAll: true), 0)
        XCTAssertFalse(ApprovalNotificationMode.options(canSeeAll: false).contains(.urgentAll))
        XCTAssertFalse(ApprovalNotificationPolicy.qualifies(item(mine: false), mode: .urgentAll, canSeeAll: false))
    }
    func testCoalescesAndLimitsPerShopWithInjectedClock() {
        var policy = ApprovalNotificationPolicy()
        let now = Date(timeIntervalSince1970: 1000)
        let rows = (0..<4).map { item(String($0)) }
        let summary = policy.plan(items: rows, seen: [], mode: .urgentMine, canSeeAll: false, deliveryEnabled: true, now: now)
        XCTAssertEqual(summary.summaryCount, 4); XCTAssertTrue(summary.singles.isEmpty)
        let singles = policy.plan(items: [item("5"), item("6"), item("7", shop: "two")], seen: summary.seen, mode: .urgentMine, canSeeAll: false, deliveryEnabled: true, now: now)
        XCTAssertEqual(singles.singles.map(\.id), ["5", "7"])
        XCTAssertTrue(policy.plan(items: [item("8")], seen: [], mode: .urgentMine, canSeeAll: false, deliveryEnabled: true, now: now.addingTimeInterval(599)).singles.isEmpty)
        XCTAssertEqual(policy.plan(items: [item("9")], seen: [], mode: .urgentMine, canSeeAll: false, deliveryEnabled: true, now: now.addingTimeInterval(600)).singles.count, 1)
    }
    func testDisabledAndUnqualifiedItemsStaySeenWithoutBanners() {
        var policy = ApprovalNotificationPolicy()
        let rows = [item(), item("other", mine: false)]
        let off = policy.plan(items: rows, seen: [], mode: .urgentMine, canSeeAll: true, deliveryEnabled: false, now: Date())
        XCTAssertEqual(off.seen, ["1", "other"]); XCTAssertTrue(off.singles.isEmpty); XCTAssertEqual(off.summaryCount, 0)
        let changed = policy.plan(items: rows, seen: off.seen, mode: .urgentAll, canSeeAll: true, deliveryEnabled: true, now: Date())
        XCTAssertTrue(changed.singles.isEmpty)
    }
    func testAllPermissionComesFromPortfolioScopes() throws {
        for (viewer, expected) in [(#"{"kind":"staff","scopes":{"mine":2,"all":10}}"#, true), (#"{"kind":"staff","scopes":{"mine":2}}"#, false), (#"{"kind":"client","scopes":{"all":2}}"#, false)] {
            XCTAssertEqual(CompanionPace.parse("{\"viewer\":\(viewer),\"shops\":[]}")?.canSeeAllShops, expected)
        }
    }
}
