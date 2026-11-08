import XCTest
import WebKit
@testable import LarkMini

final class CompanionSubframeTests: XCTestCase {
    func testAuthKitChallengeAndDocumentSubframesAreAllowed() throws {
        for raw in ["https://challenges.cloudflare.com/turnstile/v0/", "https://example.com/frame",
                    "about:blank", "about:srcdoc", "about:blank#challenge", "data:text/html,<p>frame</p>",
                    "blob:https://example.com/00000000-0000-0000-0000-000000000000"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(CompanionNavigationPolicy.subframeDecision(for: url), .allow, raw)
        }
    }

    func testUnsafeSubframeSchemesAndHTTPSUserinfoAreCancelled() throws {
        for raw in ["file:///tmp/frame.html", "smb://example.com/share", "ollie://companion",
                    "custom-scheme:action", "javascript:alert(1)", "http://example.com/frame",
                    "about:config", "about://blank", "https://user@example.com/frame", "https://user:password@example.com/frame"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(CompanionNavigationPolicy.subframeDecision(for: url), .cancel, raw)
        }
    }

    func testCrossOriginMainFrameStillRequiresExplicitLinkForExternalOpen() {
        let policy = CompanionNavigationPolicy(baseURL: URL(string: "https://outlandishteam.com")!)
        let url = URL(string: "https://challenges.cloudflare.com/turnstile/v0/")!
        XCTAssertEqual(policy.decision(for: url), .external)
        XCTAssertEqual(CompanionNavigationPolicy.externalLinkURL(url, isMainFrame: true,
                                                                navigationType: .linkActivated), url)
        for type: WKNavigationType in [.other, .formSubmitted, .formResubmitted, .backForward, .reload] {
            XCTAssertNil(CompanionNavigationPolicy.externalLinkURL(url, isMainFrame: true, navigationType: type))
        }
        XCTAssertNil(CompanionNavigationPolicy.externalLinkURL(url, isMainFrame: false,
                                                              navigationType: .linkActivated))
        // New-window requests still use their separate auth-page restriction.
        XCTAssertEqual(policy.windowOpenDecision(for: url,
            topURL: URL(string: "https://example.authkit.app/bootstrap")!), .deny)
    }
}
