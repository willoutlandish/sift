import XCTest
import AppKit
import JavaScriptCore
@testable import LarkMini

final class CompanionDragMapTests: XCTestCase {
    func testFlippedAndUnflippedCoordinatesAndScaledControls() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let rows = [CompanionDragRow(start: 0, end: 80, intervals: [100...120])]
        for flipped in [false, true] {
            let point = CGPoint(x: 220, y: flipped ? 60 : 580)
            XCTAssertEqual(CompanionDragHitTest.yFromTop(point, in: bounds, isFlipped: flipped), 40)
            XCTAssertFalse(CompanionDragHitTest.shouldDrag(point: point, in: bounds, strip: 80,
                rows: rows, isFlipped: flipped, scale: 2))
            XCTAssertTrue(CompanionDragHitTest.shouldDrag(point: point, in: bounds, strip: 80,
                rows: [], isFlipped: flipped, scale: 2))
            let outside = CGPoint(x: 220, y: flipped ? 220 : 420)
            XCTAssertFalse(CompanionDragHitTest.shouldDrag(point: outside, in: bounds, strip: 80,
                rows: [], isFlipped: flipped, scale: 2))
        }
    }

    @MainActor func testUnfocusedFirstPressAndStaleMapUseSameDecisionWithoutWaiting() {
        let view = CompanionWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                    configuration: CompanionWebConfiguration.make())
        print("CompanionWebView runtime isFlipped=\(view.isFlipped)")
        XCTAssertNil(view.window) // No window, activation or synthetic event needed.
        let now = Date(timeIntervalSince1970: 100)
        var map = CompanionDragMap(stripHeight: 90, viewportWidth: 800, updatedAt: now)
        view.dragMap = { map }
        view.isCompanionPage = { true }
        var refreshes = 0
        view.refreshDragMap = {
            refreshes += 1
            // Simulate a fast map response; the current press must still use its snapshot.
            map.rows = [CompanionDragRow(start: 0, end: 90, intervals: [90...110])]
            map.updatedAt = now.addingTimeInterval(3)
        }
        let point = CGPoint(x: 100, y: view.isFlipped ? 70 : 530)
        XCTAssertTrue(view.dragDecision(at: point, now: now.addingTimeInterval(2)).drag)
        XCTAssertEqual(refreshes, 0)
        XCTAssertTrue(view.dragDecision(at: point, now: now.addingTimeInterval(3)).drag)
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(view.dragDecision(at: point, now: now.addingTimeInterval(3)).drag)
        view.isCompanionPage = { false }
        XCTAssertFalse(view.dragDecision(at: CGPoint(x: 200, y: point.y), now: now).drag)
    }

    func testActualScriptMeasuresHeaderRailAndRefreshesRoutesAndGeometry() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var messages = [], handlers = {}, pending = [], mutate, resized, pushCalls = 0;
        var window = this; window.top = window; window.innerWidth = 400;
        var location = {origin: 'https://example.com', pathname: '/companion/app'};
        var history = {pushState: function() { pushCalls++; return 7; }, replaceState: function() { return 8; }};
        var headerBottom = 80, railHeight = 90, buttonPresent = true;
        var header = {getBoundingClientRect: () => ({width: 400, height: headerBottom, bottom: headerBottom})};
        var rail = {getBoundingClientRect: () => ({top: 0, width: 84, height: 600})};
        var document = {body: {}, documentElement: {},
          querySelectorAll: () => [header], querySelector: () => rail,
          addEventListener: (name, fn) => (handlers[name] ||= []).push(fn)};
        var button = {tagName: 'BUTTON', parentElement: document.body, getAttribute: () => null};
        document.elementFromPoint = (x, y) => buttonPresent && x >= 100 && x <= 120 && y >= 60 && y <= 80 ? button : document.body;
        window.getComputedStyle = (node, pseudo) => pseudo ?
          {content: '""', display: 'block', position: 'absolute', top: '0px', height: railHeight + 'px'} :
          {paddingTop: '52px', cursor: 'auto'};
        window.webkit = {messageHandlers: {ollieTitlebar: {postMessage: value => messages.push(value)}}};
        window.addEventListener = document.addEventListener;
        var requestAnimationFrame = fn => pending.push(fn);
        var MutationObserver = class {constructor(fn) {mutate = fn;} observe() {}};
        var ResizeObserver = class {constructor(fn) {resized = fn;} observe() {}};
        var flush = () => { while(pending.length) pending.shift()(); };
        var fire = name => (handlers[name] || []).forEach(fn => fn());
        """)
        context.evaluateScript(CompanionTitlebarScript.source(escapedOrigin: "https://example.com"))
        func evaluate(_ code: String) -> JSValue { context.evaluateScript(code)! }
        evaluate("flush()")
        XCTAssertNil(context.exception)
        XCTAssertEqual(evaluate("messages.at(-1).stripHeight").toInt32(), 90)
        XCTAssertTrue(evaluate("messages.at(-1).rows.some(row => row.intervals.length > 0)").toBool())
        XCTAssertEqual(evaluate("history.pushState({}, '', '/companion/app/next')").toInt32(), 7)
        evaluate("headerBottom = 120; buttonPresent = false; flush()")
        XCTAssertEqual(evaluate("messages.at(-1).stripHeight").toInt32(), 120)
        XCTAssertTrue(evaluate("messages.at(-1).rows.every(row => row.intervals.length === 0)").toBool())
        for trigger in ["history.replaceState({}, '', '/companion/app')", "fire('popstate')", "fire('resize')",
                        "fire('scroll')", "fire('load')", "fire('DOMContentLoaded')", "mutate()", "resized()",
                        "window.__ollieTitlebarRefresh()"] {
            let count = evaluate("messages.length").toInt32()
            evaluate("headerBottom = 300; " + trigger + "; flush()")
            XCTAssertEqual(evaluate("messages.length").toInt32(), count + 1, trigger)
            XCTAssertEqual(evaluate("messages.at(-1).stripHeight").toInt32(), 140, trigger)
        }
        evaluate("headerBottom = 20; railHeight = 0; mutate(); flush()")
        XCTAssertEqual(evaluate("messages.at(-1).stripHeight").toInt32(), 52)
        XCTAssertNil(context.exception)
    }

    func testMapKeepsAllRowsAndUnknownAgeRequestsRefresh() {
        var map = CompanionDragMap()
        XCTAssertTrue(map.needsRefresh(now: Date()))
        map.update(["stripHeight": 140, "viewportWidth": 980,
                    "rows": (0..<35).map { ["start": $0 * 4, "end": ($0 + 1) * 4, "intervals": []] as [String: Any] }],
                   now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(map.rows.count, 35)
        XCTAssertFalse(map.needsRefresh(now: Date(timeIntervalSince1970: 102)))
        XCTAssertTrue(map.needsRefresh(now: Date(timeIntervalSince1970: 102.01)))
    }
}
