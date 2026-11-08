import XCTest
import WebKit
@testable import LarkMini

final class CompanionResponseTests: XCTestCase {
    private let base = URL(string: "https://outlandishteam.com")!
    private let auth = URL(string: "https://example.authkit.app/bootstrap")!

    private func decision(_ url: URL, displayable: Bool, mainFrame: Bool = true,
                          disposition: String? = nil) -> WKNavigationResponsePolicy {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: disposition.map { ["Content-Disposition": $0] })!
        return CompanionNavigationPolicy.responseDecision(response: response, canShowMIMEType: displayable,
                                                           isMainFrame: mainFrame, baseURL: base)
    }

    func testDisplayableAuthKitMainFrameIsAllowed() {
        XCTAssertEqual(CompanionNavigationPolicy(baseURL: base).decision(for: auth), .allow)
        XCTAssertEqual(decision(auth, displayable: true), .allow)
    }

    func testDisplayableSubframesAreAllowed() {
        XCTAssertEqual(decision(base, displayable: true, mainFrame: false), .allow)
        XCTAssertEqual(decision(auth, displayable: true, mainFrame: false), .allow)
    }

    func testCrossOriginNonDisplayableResponseIsCancelled() {
        XCTAssertEqual(decision(auth, displayable: false), .cancel)
    }

    func testBaseOriginNonDisplayableMainFrameDownloads() {
        XCTAssertEqual(decision(base, displayable: false), .download)
        XCTAssertEqual(decision(base, displayable: false, mainFrame: false), .cancel)
    }

    func testAttachmentsUseDownloadRestrictionsEvenForDisplayableMIMETypes() {
        let attachment = " Attachment ; filename=report.pdf"
        XCTAssertEqual(decision(base, displayable: true, disposition: attachment), .download)
        XCTAssertEqual(decision(auth, displayable: true, disposition: attachment), .cancel)
        XCTAssertEqual(decision(base, displayable: true, mainFrame: false, disposition: attachment), .cancel)
        XCTAssertEqual(decision(auth, displayable: true, disposition: "inline; filename=attachment.pdf"), .allow)
    }
}
