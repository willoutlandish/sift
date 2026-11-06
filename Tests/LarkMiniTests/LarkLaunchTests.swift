import XCTest
@testable import LarkMini

final class LarkLaunchTests: XCTestCase {
    func testFallsBackToTheWebWhenLarkIsNotInstalled() {
        XCTAssertEqual(LarkLaunch.choice(applicationExists: true), .app)
        XCTAssertEqual(LarkLaunch.choice(applicationExists: false), .web)
    }
}
