import XCTest
@testable import LarkMini

final class InstallationTests: XCTestCase {
    @MainActor func testCompanionUserAgentConfiguration() {
        XCTAssertEqual(CompanionWebConfiguration.userAgent(version: "0.1.1"), "Ollie/0.1.1")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        XCTAssertEqual(CompanionWebConfiguration.make().applicationNameForUserAgent, "Ollie/" + version)
    }

    func testDefaultsAndSavedSettings() throws {
        XCTAssertEqual(Settings().showIn, .edge)
        XCTAssertTrue(Settings().showInDock)
        let legacy = try JSONDecoder().decode(Settings.self, from: Data(#"{"showIn":"menubar"}"#.utf8))
        XCTAssertEqual(legacy.showIn, .menubar)
        XCTAssertTrue(legacy.showInDock)
        let saved = try JSONDecoder().decode(Settings.self, from: Data(#"{"showIn":"both","showInDock":false}"#.utf8))
        XCTAssertEqual(saved.showIn, .both)
        XCTAssertFalse(saved.showInDock)
        XCTAssertEqual(DockRouting.destination(panelOpen: false), .companion)
        XCTAssertEqual(DockRouting.destination(panelOpen: true), .companion)
        XCTAssertTrue(DockRouting.shouldRaiseOnActivation(panelInteraction: false))
        XCTAssertFalse(DockRouting.shouldRaiseOnActivation(panelInteraction: true))
        XCTAssertEqual(CompanionConfig.defaultURL(development: false, devURL: "http://localhost:8090"), "https://outlandishdigital.us")
        XCTAssertEqual(CompanionConfig.defaultURL(development: true, devURL: "http://localhost:8090"), "http://localhost:8090")
    }

    func testFreshStateUsesBuildDefaultWithoutPersistingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let state = StateFile(url: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(state.current.companionURL)
        XCTAssertEqual(state.current.effectiveCompanionURL, CompanionConfig.defaultURL)
        // Startup can normalize settings or save the profile without pinning the host.
        state.update { $0.settings.panelWidth = Settings.validWidth($0.settings.panelWidth) }
        state.update { $0.meOpenId = "test-profile" }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(json["companionURL"])
        let reopened = StateFile(url: file).current
        XCTAssertNil(reopened.companionURL)
        XCTAssertEqual(reopened.effectiveCompanionURL, CompanionConfig.defaultURL)
        XCTAssertEqual(reopened.companionURL(defaultingTo: "https://next.example.com"), "https://next.example.com")
        let legacy = try JSONDecoder().decode(AppState.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.companionURL)
        XCTAssertEqual(legacy.effectiveCompanionURL, CompanionConfig.defaultURL)
    }

    func testExplicitCompanionAddressSurvivesBuildDefaultChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let state = StateFile(url: file)
        // An explicit selection stays pinned even if it equals today's default.
        for address in ["https://chosen.example.com", CompanionConfig.productionURL] {
            state.update { $0.companionURL = address }
            let reopened = StateFile(url: file).current
            XCTAssertEqual(reopened.companionURL, address)
            XCTAssertEqual(reopened.companionURL(defaultingTo: "https://next.example.com"), address)
        }
        state.update { $0.companionURL = nil }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(json["companionURL"])
        XCTAssertEqual(StateFile(url: file).current.effectiveCompanionURL, CompanionConfig.defaultURL)
    }

    func testCLIOpenRequestsForegroundButURLSchemeDoesNot() {
        XCTAssertTrue(CompanionOpenSource.cli.requestsForeground)
        XCTAssertFalse(CompanionOpenSource.urlScheme.requestsForeground)
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
