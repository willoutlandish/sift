import XCTest
@testable import LarkMini

final class PanelEdgeTests: XCTestCase {
    func testSnapBothEdgesAndClampAcrossOffsetDisplays() {
        let visible = CGRect(x: -1440, y: 30, width: 1440, height: 870)
        for (x, edge): (CGFloat, PanelEdgePosition.Edge) in [(-1500, .left), (-200, .right)] {
            let position = PanelGeometry.snap(CGRect(x: x, y: 1000, width: 320, height: 560), in: visible, margin: 12)
            XCTAssertEqual(position.edge, edge)
            let frame = PanelGeometry.edgeFrame(size: CGSize(width: 320, height: 560), in: visible, position: position, margin: 12)
            XCTAssertTrue(visible.insetBy(dx: 12, dy: 12).contains(frame))
            XCTAssertEqual(edge == .left ? frame.minX : frame.maxX, edge == .left ? -1428 : -12)
        }
        let position = PanelEdgePosition(edge: .left, verticalFraction: 0.5)
        let duck = PanelGeometry.edgeFrame(size: CGSize(width: 72, height: 72), in: visible, position: position, margin: 12)
        let panel = PanelGeometry.edgeFrame(size: CGSize(width: 320, height: 560), in: visible, position: position, margin: 12)
        XCTAssertEqual(duck.midY, panel.midY)
        let small = CGRect(x: 0, y: 0, width: 250, height: 250)
        XCTAssertTrue(small.contains(PanelGeometry.edgeFrame(size: CGSize(width: 500, height: 560), in: small, position: position, margin: 12)))
    }

    func testMovementThresholdSuppressesClickAfterDraggingBackToStart() {
        var drag = PanelPointerDrag()
        drag.begin(at: .zero)
        XCTAssertNil(drag.move(to: CGPoint(x: 2, y: 2)))
        XCTAssertFalse(drag.finish())
        drag.begin(at: .zero)
        XCTAssertNotNil(drag.move(to: CGPoint(x: 6, y: 0)))
        XCTAssertNotNil(drag.move(to: .zero))
        XCTAssertTrue(drag.finish())
    }

    func testPositionsPersistIndependentlyPerDisplay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = StateFile(url: url)
        state.update { $0.edgePositions["display-a"] = PanelEdgePosition(edge: .left, verticalFraction: 0.25) }
        state.update { $0.edgePositions["display-b"] = PanelEdgePosition(edge: .right, verticalFraction: 0.75) }
        let saved = StateFile(url: url).current.edgePositions
        XCTAssertEqual(saved["display-a"], PanelEdgePosition(edge: .left, verticalFraction: 0.25))
        XCTAssertEqual(saved["display-b"], PanelEdgePosition(edge: .right, verticalFraction: 0.75))
        XCTAssertTrue(try JSONDecoder().decode(AppState.self, from: Data("{}".utf8)).edgePositions.isEmpty)
    }
}
