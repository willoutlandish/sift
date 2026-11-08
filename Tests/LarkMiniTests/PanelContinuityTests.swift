import XCTest
@testable import LarkMini

final class PanelContinuityTests: XCTestCase {
    @MainActor func testCollapseKeepsPaneAndShop() {
        let store = Store.demo()
        store.ollieScreen = .activity(resource: "one", name: "One")
        store.isExpanded = false
        store.isExpanded = true
        XCTAssertEqual(store.ollieScreen, .activity(resource: "one", name: "One"))
        store.showInbox()
        store.isExpanded = false
        store.isExpanded = true
        XCTAssertEqual(store.pane, .lark)
    }
    func testOutsideClickHonorsPreference() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        for expanded in [true, false] { for enabled in [true, false] {
            XCTAssertEqual(PanelOutsideClick.shouldCollapse(expanded: expanded, enabled: enabled, point: CGPoint(x: 200, y: 200), frame: frame), expanded && enabled)
            XCTAssertFalse(PanelOutsideClick.shouldCollapse(expanded: expanded, enabled: enabled, point: CGPoint(x: 50, y: 50), frame: frame))
        } }
    }
    @MainActor func testShowRestoresDuckAlpha() {
        let store = Store.demo()
        store.isExpanded = false
        let controller = PanelController(store: store)
        controller.panel.alphaValue = 0
        controller.show()
        XCTAssertEqual(controller.panel.alphaValue, 1)
        controller.panel.orderOut(nil)
    }
}
