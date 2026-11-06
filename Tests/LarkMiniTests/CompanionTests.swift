import XCTest
@testable import LarkMini

final class CompanionTests: XCTestCase {
    func testURLValidationAcceptsHTTPAndHTTPSOnly() {
        XCTAssertEqual(CompanionConfig.validatedURL("http://100.113.131.96:8090")?.absoluteString,
                       "http://100.113.131.96:8090")
        XCTAssertEqual(CompanionConfig.validatedURL(" https://example.com/companion ")?.absoluteString,
                       "https://example.com/companion")
        XCTAssertNil(CompanionConfig.validatedURL("ftp://example.com"))
        XCTAssertNil(CompanionConfig.validatedURL("javascript:alert(1)"))
        XCTAssertNil(CompanionConfig.validatedURL("example.com"))
        XCTAssertNil(CompanionConfig.validatedURL("https:///missing-host"))
        XCTAssertNil(CompanionConfig.validatedURL("https://user:secret@example.com"))
        XCTAssertNil(CompanionConfig.validatedURL(""))
    }

    func testTargetPathStaysOnTheConfiguredOrigin() {
        let base = URL(string: "http://100.113.131.96:8090")!
        XCTAssertEqual(CompanionConfig.targetURL(base: base, path: "/companion/app/abc/messages/management")?.absoluteString,
                       "http://100.113.131.96:8090/companion/app/abc/messages/management")
        XCTAssertEqual(CompanionConfig.targetURL(base: base, path: "companion/app/abc")?.absoluteString,
                       "http://100.113.131.96:8090/companion/app/abc")
        XCTAssertEqual(CompanionConfig.targetURL(base: base, path: nil)?.absoluteString,
                       "http://100.113.131.96:8090/companion/app")
        XCTAssertEqual(CompanionConfig.targetURL(base: base, path: "//example.com/elsewhere")?.absoluteString,
                       "http://100.113.131.96:8090/companion/app")
    }

    func testCompanionPathOnlyAcceptsPathsUnderCompanion() {
        XCTAssertEqual(CompanionPath.accepted(nil), "/companion/app")
        XCTAssertEqual(CompanionPath.accepted("/companion/app/6bd/messages/management"),
                       "/companion/app/6bd/messages/management")
        XCTAssertEqual(CompanionPath.accepted("companion/app/6bd"), "/companion/app/6bd")
        XCTAssertEqual(CompanionPath.accepted("/other"), "/companion/app")
        XCTAssertEqual(CompanionPath.accepted("/companion/../secret"), "/companion/app")
        XCTAssertEqual(CompanionPath.accepted("/companion/app/%2e%2e/secret"), "/companion/app")
        XCTAssertEqual(CompanionPath.accepted("/companion/app?tab=plans"), "/companion/app?tab=plans")
    }

    func testMediaCaptureMatchesOnlyTheConfiguredOrigin() {
        let base = URL(string: "http://100.113.131.96:8090")!
        XCTAssertTrue(CompanionConfig.originMatches(
            scheme: "http", host: "100.113.131.96", port: 8090, base: base))
        XCTAssertFalse(CompanionConfig.originMatches(
            scheme: "http", host: "example.com", port: 8090, base: base))
        XCTAssertFalse(CompanionConfig.originMatches(
            scheme: "https", host: "id.outlandish.com", port: 443, base: base))
        XCTAssertFalse(CompanionConfig.originMatches(
            scheme: "https", host: "open.larksuite.com", port: 443, base: base))

        let secure = URL(string: "https://example.com")!
        XCTAssertTrue(CompanionConfig.originMatches(
            scheme: "https", host: "example.com", port: 0, base: secure))
    }


    func testCLIPathKeepsSameOriginAuthWhileSchemePathFallsBack() {
        let base = URL(string: "http://100.113.131.96:8090")!
        let auth = "/e2e/auth?secret=test&persona=shop_op"
        XCTAssertEqual(CompanionConfig.targetURL(base: base, path: auth)?.absoluteString,
                       "http://100.113.131.96:8090/companion/app")
        XCTAssertEqual(CompanionConfig.cliTargetURL(base: base, path: auth)?.absoluteString,
                       "http://100.113.131.96:8090/e2e/auth?secret=test&persona=shop_op")
        XCTAssertNil(CompanionConfig.cliTargetURL(base: base, path: "https://example.com/e2e/auth"))
        XCTAssertNil(CompanionConfig.cliTargetURL(base: base, path: "//example.com/e2e/auth"))
    }


    @MainActor
    func testProbeCoordinatorCoalescesConcurrentChecksAndCaches() {
        var cookieCalls = 0
        var signInCalls = 0
        var release: ((Bool) -> Void)?
        let coordinator = CompanionProbeCoordinator(
            cookieCheck: { _, completion in
                cookieCalls += 1
                completion(true)
            },
            signInCheck: { _, completion in
                signInCalls += 1
                release = completion
            }
        )
        let base = URL(string: "http://100.113.131.96:8090")!
        var first: CompanionProbeCoordinator.Result?
        var second: CompanionProbeCoordinator.Result?

        coordinator.check(baseURL: base) { first = $0 }
        coordinator.check(baseURL: base) { second = $0 }
        XCTAssertEqual(cookieCalls, 1)
        XCTAssertEqual(signInCalls, 1)

        release?(true)
        XCTAssertEqual(first?.signedIn, true)
        XCTAssertEqual(first?.cookiePresent, true)
        XCTAssertEqual(second?.signedIn, true)

        var third: CompanionProbeCoordinator.Result?
        coordinator.check(baseURL: base) { third = $0 }
        XCTAssertEqual(cookieCalls, 1)
        XCTAssertEqual(signInCalls, 1)
        XCTAssertEqual(third?.signedIn, true)
    }

    func testSignInProbeRejectsSignInPaths() {
        XCTAssertTrue(CompanionSignInProbe.isSignIn(URL(string: "http://100.113.131.96:8090/outlandish/sign-in")!))
        XCTAssertTrue(CompanionSignInProbe.isSignIn(URL(string: "http://100.113.131.96:8090/login")!))
        XCTAssertFalse(CompanionSignInProbe.isSignIn(URL(string: "http://100.113.131.96:8090/companion/app")!))
        XCTAssertTrue(CompanionSignInProbe.isSignIn(nil))
    }


    func testNavigationAllowsWorkOSAndAuthKitButDeniesAuthPopups() {
        let base = URL(string: "http://100.113.131.96:8090")!
        let policy = CompanionNavigationPolicy(baseURL: base)

        XCTAssertEqual(policy.decision(for: URL(string: "https://api.workos.com/user_management/authorize")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://tenant.authkit.app/login")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://a.b.authkit.app/login")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "https://accounts.larksuite.com/accounts/page/login")!), .allow)

        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "https://api.workos.com/user_management/authorize")!,
                                                  topURL: base), .deny)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "https://tenant.authkit.app/login")!,
                                                  topURL: base), .deny)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "http://100.113.131.96:8090/companion/app/abc")!,
                                                  topURL: base), .loadInCompanion)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "https://example.com/report")!,
                                                  topURL: base), .openExternally)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "http://100.113.131.96:8090/companion/app")!,
                                                  topURL: URL(string: "https://api.workos.com/login")!), .deny)
    }

    func testBridgeValidatesArgumentsAndOrigins() {
        let base = URL(string: "http://100.113.131.96:8090")!
        XCTAssertTrue(CompanionBridge.allowedPage(URL(string: "http://100.113.131.96:8090/companion/app/abc")!, base: base))
        XCTAssertFalse(CompanionBridge.allowedPage(URL(string: "https://example.com/companion/app")!, base: base))
        XCTAssertFalse(CompanionBridge.allowedPage(URL(string: "http://100.113.131.96:8090/e2e/auth")!, base: base))

        XCTAssertEqual(CompanionBridge.validate(method: "setBadge", arguments: [3]), .setBadge(3))
        XCTAssertEqual(CompanionBridge.validate(method: "setBadge", arguments: [-1]), .invalid)
        XCTAssertEqual(CompanionBridge.validate(method: "notify", arguments: ["Agent", "Needs you"]),
                       .notify("Agent", "Needs you"))
        XCTAssertEqual(CompanionBridge.validate(method: "notify", arguments: ["", "Needs you"]), .invalid)
        XCTAssertEqual(CompanionBridge.validate(method: "openExternal", arguments: ["https://example.com"]),
                       .openExternal(URL(string: "https://example.com")!))
        XCTAssertEqual(CompanionBridge.validate(method: "openExternal", arguments: ["http://example.com"]), .invalid)
        XCTAssertEqual(CompanionBridge.validate(method: "openSpace", arguments: ["x", "https://example.com"]), .unsupported)
    }

    func testApprovalsDiffClickPathAndSeenStore() {
        let first = CompanionApproval(id: "a", label: "North agent", question: "Approve the reorder",
                                      resource: "north", shopName: "North Studio")
        let second = CompanionApproval(id: "b", label: "Harbor agent", question: "Pause collection",
                                       resource: nil, shopName: "Harbor & Co")
        XCTAssertEqual(CompanionApprovals.diff(current: [first, second], seen: ["a"]), [second])
        XCTAssertEqual(first.clickPath, "/companion/app/north/approvals")
        XCTAssertEqual(second.clickPath, "/companion/app/approvals")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ollie-approvals-\(UUID().uuidString).json")
        let store = CompanionApprovalsSeenStore(url: url)
        XCTAssertNil(store.load())
        store.save(["a", "b"])
        XCTAssertEqual(store.load(), ["a", "b"])
        try? FileManager.default.removeItem(at: url)
    }

    func testNavigationAllowsTheOriginAndSignInHosts() {
        let base = URL(string: "http://100.113.131.96:8090")!
        let policy = CompanionNavigationPolicy(baseURL: base, signInHosts: ["outlandish.com"])

        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8090/companion/app/abc")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8090/outlandish/sign-in")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://outlandish.com/sign-in")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://id.outlandish.com/login")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "about:blank")!), .allow)

        let defaults = CompanionNavigationPolicy(baseURL: base)
        XCTAssertEqual(defaults.decision(for: URL(string: "https://open.larksuite.com/open-apis/authen/v1/index")!), .allow)
    }

    func testNavigationSendsOtherLinksToTheBrowser() {
        let policy = CompanionNavigationPolicy(baseURL: URL(string: "http://100.113.131.96:8090")!,
                                               signInHosts: ["outlandish.com"])

        XCTAssertEqual(policy.decision(for: URL(string: "https://example.com/report")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8091/companion")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "https://notoutlandish.com/login")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "mailto:help@example.com")!), .external)
    }
}
