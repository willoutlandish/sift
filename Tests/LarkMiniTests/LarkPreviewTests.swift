import XCTest
@testable import LarkMini

final class LarkPreviewTests: XCTestCase {
    func testHTMLPreviewBecomesPlainTextWithoutLoadingAnything() {
        XCTAssertEqual(LarkPreview.plain("<p>SUN-THUR &amp; Friday</p><p>9&#58;00&nbsp;AM</p>"), "SUN-THUR & Friday 9:00 AM")
        XCTAssertEqual(LarkPreview.plain("<script>bad()</script><img src='https://example.com'>Hello"), "Hello")
        XCTAssertEqual(LarkPreview.plain("2 < 3 &amp; 4 > 1"), "2 < 3 & 4 > 1")
    }
    func testCardPreviewUsesHeaderAndNestedText() throws {
        for content in [#"{"header":{"title":{"tag":"plain_text","content":"Release ready"}},"elements":[{"tag":"div","text":{"tag":"lark_md","content":"Review the release"}}]}"#,
                        #"{"header":{"title":{"content":"Release ready"}},"body":{"elements":[{"tag":"markdown","content":"Review the release"}]}}"#] {
            let message = try XCTUnwrap(LarkAPI.parseMessage(["message_id":"one", "msg_type":"interactive", "body":["content":content]], chatId: "chat", meId: "me"))
            XCTAssertTrue(Store.previewText(for: message).contains("Release ready"))
            XCTAssertTrue(Store.previewText(for: message).contains("Review the release"))
        }
    }
}
