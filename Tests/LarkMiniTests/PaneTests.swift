import XCTest
@testable import LarkMini

final class PaneTests: XCTestCase {
    func testEverySelectedPaneMapsToItsOwnRailHighlight() {
        XCTAssertEqual(Store.Pane.lark.railItem, .lark)
        XCTAssertEqual(Store.Pane.ollie.railItem, .ollie)
        XCTAssertEqual(Store.Pane.control.railItem, .control)
        XCTAssertEqual(Store.Pane.settings.railItem, .settings)
        XCTAssertEqual(Store.Pane.chat("chat-1").railItem, .chat("chat-1"))
    }
}
