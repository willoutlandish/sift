import XCTest
@testable import LarkMini

final class InstallationTests: XCTestCase {
    func testDefaultsAndSavedSettings() throws {
        XCTAssertEqual(Settings().showIn, .edge)
        XCTAssertTrue(Settings().showInDock)
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"showIn":"menubar"}"#.utf8))
        XCTAssertEqual(legacy.showIn, .menubar)
        XCTAssertTrue(legacy.showInDock)
        let saved = try JSONDecoder().decode(Settings.self, from: Data(#"{"showIn":"both","showInDock":false}"#.utf8))
        XCTAssertEqual(saved.showIn, .both)
        XCTAssertFalse(saved.showInDock)
        XCTAssertEqual(DockRouting.destination(panelOpen: false), .panel)
        XCTAssertEqual(DockRouting.destination(panelOpen: true), .companion)
        XCTAssertEqual(CompanionConfig.defaultURL(development: false, devURL: "http://localhost:8090"), "https://outlandishdigital.us")
        XCTAssertEqual(CompanionConfig.defaultURL(development: true, devURL: "http://localhost:8090"), "http://localhost:8090")
    }

    func testCredentialFreeLarkIsReadOnlyAndRefusalsStayRefused() throws {
        XCTAssertFalse(LarkSource.select(hasCredentials: false).canWrite)
        XCTAssertTrue(LarkSource.select(hasCredentials: true).canWrite)
        XCTAssertNil(CompanionLarkRead.path(query: "a"))
        XCTAssertTrue(CompanionLarkRead.path(query: "Design Room")!.contains("lark-chats?query=Design%20Room"))
        XCTAssertTrue(CompanionLarkRead.path(query: "")!.contains("lark-inbox"))
        let good = #"{"readOnly":true,"source":{"state":"partial"},"data":[{"conversation":{"ref":{"externalId":"oc_abc"},"title":"Room"}}]}"#
        XCTAssertEqual(CompanionLarkRead.parse(.init(status: 200, contentType: "application/json", body: good, url: ""))?.first?.title, "Room")
        XCTAssertNil(CompanionLarkRead.parse(.init(status: 403, contentType: "application/json", body: good, url: "")))
        XCTAssertNil(CompanionLarkRead.parse(.init(status: 200, contentType: "application/json", body: good.replacingOccurrences(of: "partial", with: "authorization_required"), url: "")))
    }
}
