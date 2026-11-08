import XCTest
import Sentry
import CryptoKit
@testable import LarkMini

final class ReleaseSafetyTests: XCTestCase {
    func testPublishedSparkleKeyMatchesLeadVerificationVector() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Support/Info.plist")), format: nil) as! [String: Any]
        let bytes = try XCTUnwrap(Data(base64Encoded: plist["SUPublicEDKey"] as! String))
        XCTAssertEqual(bytes.count, 32)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
        let signature = try XCTUnwrap(Data(base64Encoded: "OH6hxq665jPfqGZyVS6SXSoqhTvDsMLHe1RDsSzt9QGvTjaPU8SALmXsJGXzlok0yIUn/ZDhVB9kfn0OapnCBg=="))
        XCTAssertTrue(key.isValidSignature(signature, for: Data("ollie-sparkle-key-check".utf8)))
        XCTAssertFalse(key.isValidSignature(signature, for: Data("ollie-sparkle-key-check-tampered".utf8)))
    }

    func testQuietUpdateRequiresThreeMinutesAndNoInteractions() {
        let start = Date(timeIntervalSince1970: 1000)
        var policy = QuietUpdatePolicy(lastActivity: start)
        XCTAssertFalse(policy.mayInstall(now: start.addingTimeInterval(179)))
        XCTAssertTrue(policy.mayInstall(now: start.addingTimeInterval(180)))
        for key in [\QuietUpdatePolicy.panelOpen, \QuietUpdatePolicy.windowFocused,
                    \QuietUpdatePolicy.confirmationOpen, \QuietUpdatePolicy.decisionInFlight] {
            var busy = QuietUpdatePolicy(lastActivity: start)
            busy[keyPath: key] = true
            XCTAssertFalse(busy.mayInstall(now: start.addingTimeInterval(500)))
            busy[keyPath: key] = false
            XCTAssertFalse(busy.mayInstall(now: start.addingTimeInterval(679)))
            XCTAssertTrue(busy.mayInstall(now: start.addingTimeInterval(680)))
        }
    }

    func testCriticalGateKeepsHistoricalCriticalRequirementAndSparkleOrdering() {
        typealias Release = RequiredUpdateGate.Release
        XCTAssertNil(RequiredUpdateGate.requiredVersion(current: "2", releases: []))
        XCTAssertNil(RequiredUpdateGate.requiredVersion(current: "2", releases: [Release(version: "2", critical: true)]))
        XCTAssertEqual(RequiredUpdateGate.requiredVersion(current: "2", releases: [Release(version: "10", critical: true), Release(version: "3", critical: false)]), "10")
        XCTAssertEqual(RequiredUpdateGate.requiredVersion(current: "2", releases: [Release(version: "3", critical: true), Release(version: "10", critical: false)]), "10")
        XCTAssertNil(RequiredUpdateGate.requiredVersion(current: "3", releases: [Release(version: "3", critical: true), Release(version: "10", critical: false)]))
        XCTAssertNil(RequiredUpdateGate.requiredVersion(current: "11", releases: [Release(version: "10", critical: true)]))
    }

    func testCrashPayloadExcludesPersonalContent() throws {
        let event = Event(level: .fatal)
        event.message = SentryMessage(formatted: "private message")
        event.extra = ["cookie": "private-cookie"]
        event.tags = ["url": "https://example.com/customer/123"]
        event.exceptions = [Exception(value: "private message", type: "private type")]
        let image = DebugMeta()
        image.debugID = "F8C93251-CECC-4C82-AEBC-FA5AC935D786"
        image.type = "macho"
        image.imageAddress = "0x1000"
        image.imageVmAddress = "0x2000"
        image.imageSize = 4096
        image.codeFile = "/private/personal/customer.dylib"
        image.name = "personal"
        let invalid = DebugMeta()
        invalid.debugID = "private content"
        invalid.imageAddress = "0x1234"
        event.debugMeta = [image, invalid]
        let safe = try XCTUnwrap(CrashReporting.sanitized(event))
        XCTAssertEqual(safe.debugMeta?.count, 1)
        XCTAssertEqual(safe.debugMeta?.first?.debugID, image.debugID)
        XCTAssertEqual(safe.debugMeta?.first?.imageAddress, "0x1000")
        XCTAssertEqual(safe.debugMeta?.first?.imageVmAddress, "0x2000")
        XCTAssertEqual(safe.debugMeta?.first?.imageSize, 4096)
        XCTAssertNil(safe.debugMeta?.first?.codeFile)
        XCTAssertNil(safe.debugMeta?.first?.name)
        XCTAssertNil(safe.message)
        XCTAssertNil(safe.extra)
        XCTAssertNil(safe.request)
        XCTAssertNil(safe.user)
        XCTAssertNil(safe.breadcrumbs)
        XCTAssertEqual(Set(safe.tags?.keys.map { $0 } ?? []), ["app_version", "app_identity"])
        XCTAssertEqual(safe.exceptions?.first?.value, "Native crash")
        XCTAssertNil(CrashReporting.sanitized(Event(level: .info)))
    }

    func testReleaseScanRejectsDevHostsAndCredentialsWithoutPrintingValues() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = fixture.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Support/Info.plist")), format: nil)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        func scan() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [root.appendingPathComponent("scripts/check-release.py").path, fixture.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        try Data("certificate 1[field.1.2.840.113635.100.6.2.6]".utf8).write(to: contents.appendingPathComponent("fixture"))
        XCTAssertEqual(try scan(), 0)
        let devInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Support/Dev.plist")), format: nil) as! [String: Any]
        let developmentURL = try XCTUnwrap(devInfo["OllieDevelopmentURL"] as? String)
        for rejected in [developmentURL, "e2e-" + "local-test-secret", "app_secret=" + String(repeating: "X", count: 32), "access_token=" + String(repeating: "Y", count: 32)] {
            try Data(rejected.utf8).write(to: contents.appendingPathComponent("fixture"))
            XCTAssertNotEqual(try scan(), 0)
        }
    }
}
