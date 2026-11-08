import XCTest
import JavaScriptCore
@testable import LarkMini

final class ControlErrorTests: XCTestCase {
    func testStructuredErrorsInSwiftAndReader() {
        XCTAssertTrue(ControlError.message(["error": ["code": "DAEMON_UNREACHABLE", "message": [:]]]).contains("DAEMON_UNREACHABLE"))
        XCTAssertEqual(ControlError.message(["code": "MISSING", "message": "Seat not found"]), "Seat not found (MISSING)")
        XCTAssertEqual(ControlError.message("[object Object]"), ControlError.fallback)
        let js = JSContext()!
        js.evaluateScript(ControlError.script)
        XCTAssertEqual(js.evaluateScript("errorReason({code:'MISSING', message:{message:'Seat not found'}})")?.toString(), "Seat not found (MISSING)")
        XCTAssertTrue(js.evaluateScript("errorReason({error:{code:'DAEMON_UNREACHABLE'}})")!.toString().contains("DAEMON_UNREACHABLE"))
    }
    func testKeepsLastGoodAsksAsStaleThenRecovers() {
        let ask = OpenAsk(id: "1", plan: "", title: "", question: "Review?", recommendation: "", link: nil)
        let stale = AskReading.unavailable("Offline").retainingLastGood(.available([ask]))
        XCTAssertEqual(stale, .stale([ask], "Offline"))
        XCTAssertEqual(stale.asks, [ask])
        XCTAssertEqual(AskReading.available([]).retainingLastGood(stale), .available([]))
    }
}
