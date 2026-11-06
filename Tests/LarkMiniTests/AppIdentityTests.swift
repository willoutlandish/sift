import XCTest
@testable import LarkMini

final class AppIdentityTests: XCTestCase {
    func testDevelopmentIdentityIsIsolated() {
        let dev = "com.outlandish.ollie.dev"
        XCTAssertTrue(AppIdentity.isDevelopment(bundleIdentifier: dev))
        XCTAssertEqual(AppIdentity.urlScheme(bundleIdentifier: dev), "ollie-dev")
        XCTAssertEqual(AppIdentity.supportFolder(bundleIdentifier: dev), "Ollie Dev")
        XCTAssertEqual(AppIdentity.notificationName("companion-status-request", bundleIdentifier: dev),
                       "companion-status-request.com.outlandish.ollie.dev")
    }

    func testReleaseIdentityStaysOllie() {
        let real = "com.outlandish.ollie"
        XCTAssertFalse(AppIdentity.isDevelopment(bundleIdentifier: real))
        XCTAssertEqual(AppIdentity.urlScheme(bundleIdentifier: real), "ollie")
        XCTAssertEqual(AppIdentity.supportFolder(bundleIdentifier: real), "Ollie")
        XCTAssertEqual(AppIdentity.notificationName("companion-status-request", bundleIdentifier: real),
                       "companion-status-request.com.outlandish.ollie")
    }
}
