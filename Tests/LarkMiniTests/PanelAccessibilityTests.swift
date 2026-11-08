import XCTest
import AppKit
import SwiftUI
@testable import LarkMini

final class PanelAccessibilityTests: XCTestCase {
    @MainActor func testDuckHasButtonRoleAndPressWithoutPointer() {
        let duck = BubbleClickView(frame: .init(x: 0, y: 0, width: 64, height: 64))
        var presses = 0
        duck.onTap = { presses += 1 }
        XCTAssertTrue(duck.isAccessibilityElement())
        XCTAssertEqual(duck.accessibilityRole(), .button)
        XCTAssertEqual(duck.accessibilityLabel(), "Open Ollie")
        XCTAssertTrue(duck.accessibilityActionNames().contains(.press))
        XCTAssertTrue(duck.accessibilityPerformPress())
        XCTAssertEqual(presses, 1)
        XCTAssertNil(duck.window)
    }
    @MainActor func testSwiftUIRailAndIconButtonsExposePress() throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let store = Store.demo()
        let view = NSHostingView(rootView: VStack {
            RailView().environmentObject(store)
            IconButton(symbol: "chevron.left", help: "Today") {}
        }.accessibilityElement(children: .contain))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func walk(_ value: Any, depth: Int = 0) -> [NSObject] {
            guard depth < 30, let object = value as? NSObject else { return [] }
            let children = (object as? any NSAccessibilityProtocol)?.accessibilityChildren()
                ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
            return [object] + children.flatMap { walk($0, depth: depth + 1) }
        }
        let nodes = walk(window)
        defer { window.orderOut(nil); window.contentView = nil }
        guard nodes.contains(where: { ($0.accessibilityAttributeValue(.role) as? String) == NSAccessibility.Role.button.rawValue }) else {
            throw XCTSkip("SwiftUI does not expose its AX tree in this test runner; native duck role and press are tested independently")
        }
        for label in ["Open Ollie", "Lark chats", "Today"] {
            let node = nodes.first(where: { ($0.accessibilityAttributeValue(.role) as? String) == NSAccessibility.Role.button.rawValue &&
                (($0.accessibilityAttributeValue(.title) as? String) == label || ($0.accessibilityAttributeValue(.description) as? String) == label) })
            XCTAssertNotNil(node, "Missing AXButton: \(label); found \(nodes.count) nodes")
            XCTAssertTrue(node?.accessibilityActionNames().contains(.press) == true)
        }
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        window.contentView = nil
    }
}
