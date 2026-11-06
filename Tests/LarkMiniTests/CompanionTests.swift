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
        XCTAssertNil(CompanionConfig.validatedURL("http://example.com"))
        XCTAssertNil(CompanionConfig.validatedURL("https://user:secret@example.com"))
        XCTAssertNil(CompanionConfig.validatedURL(""))
        XCTAssertNotNil(CompanionConfig.validatedURL("http://localhost:8090"))
        XCTAssertNotNil(CompanionConfig.validatedURL("http://dev.preview.test:8090"))
        XCTAssertNotNil(CompanionConfig.validatedURL("http://100.64.0.1:8090"))
        XCTAssertNil(CompanionConfig.validatedURL("http://100.128.0.1:8090"))
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


    func testNavigationKeepsOLIDInTheWindowAndDeniesLarkPopups() {
        let base = URL(string: "http://100.113.131.96:8090")!
        let policy = CompanionNavigationPolicy(baseURL: base)

        XCTAssertEqual(policy.decision(for: URL(string: "https://api.workos.com/user_management/authorize")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://tenant.authkit.app/login")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://a.b.authkit.app/login")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://login.live.com/oauth20_authorize.srf")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://login.microsoftonline.com.evil.example/login")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "https://accounts.larksuite.com/accounts/page/login")!), .allow)

        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "https://api.workos.com/user_management/authorize")!,
                                                  topURL: base), .loadInCompanion)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "https://tenant.authkit.app/login")!,
                                                  topURL: base), .loadInCompanion)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                                                  topURL: base), .loadInCompanion)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "https://accounts.larksuite.com/accounts/page/login")!,
                                                  topURL: base), .deny)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "http://100.113.131.96:8090/companion/app/abc")!,
                                                  topURL: base), .loadInCompanion)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "https://example.com/report")!,
                                                  topURL: base), .openExternally)
        XCTAssertEqual(policy.windowOpenDecision(for: URL(string: "http://100.113.131.96:8090/companion/app")!,
                                                  topURL: URL(string: "https://api.workos.com/login")!), .deny)
    }

    func testOllieDevIsReadOnlyOnlyOnProduction() {
        let production = URL(string: "https://outlandishdigital.us/companion/app")!
        XCTAssertTrue(CompanionWriteGuard.isReadOnly(baseURL: production, development: true))
        XCTAssertTrue(CompanionWriteGuard.isReadOnly(baseURL: URL(string: "https://www.outlandishdigital.us")!,
                                                     development: true))
        XCTAssertFalse(CompanionWriteGuard.isReadOnly(baseURL: production, development: false))
        XCTAssertFalse(CompanionWriteGuard.isReadOnly(baseURL: URL(string: "http://100.113.131.96:8090")!,
                                                      development: true))
        XCTAssertTrue(CompanionWriteGuard.isReadOnly(baseURL: URL(string: "https://notoutlandishdigital.us")!,
                                                     development: true))
        XCTAssertFalse(CompanionWriteGuard.isReadOnly(baseURL: URL(string: "http://127.0.0.1:8090")!,
                                                      development: true))
        XCTAssertFalse(CompanionWriteGuard.isReadOnly(baseURL: URL(string: "http://preview.test")!,
                                                      development: true))
        XCTAssertEqual(CompanionWriteGuard.refusal,
                       "Ollie Dev is read-only on production. Use your real Ollie to approve.")
    }

    @MainActor func testActivityOpenPathsUseAgentAndShopPages() {
        XCTAssertEqual(CompanionActivity.agentPagePath(resource: "shop/a", agent: "agent b"),
                       "/companion/app/shop%2Fa/people/agent%20b?activityPanel=agent%20b")
        XCTAssertEqual(CompanionActivity.shopPagePath(resource: "shop/a"),
                       "/companion/app/shop%2Fa/messages/management?activityPanel=ollie")
    }

    func testCompanionTargetKeepsActivityPanelQuery() throws {
        let base = try XCTUnwrap(URL(string: "https://outlandishdigital.us"))
        let target = try XCTUnwrap(CompanionConfig.targetURL(
            base: base,
            path: "/companion/app/shop/people/agent?activityPanel=agent"))
        XCTAssertEqual(target.absoluteString,
                       "https://outlandishdigital.us/companion/app/shop/people/agent?activityPanel=agent")
    }

    func testLarkPopupsAreOffByDefault() throws {
        XCTAssertFalse(Settings().showLarkPopups)
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(Settings()))
        XCTAssertFalse(decoded.showLarkPopups)
    }


    func testNativeTitlebarDragUsesSampledControlIntervals() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        // A full-width tabindex container is absent from the map; only its button is present.
        let row = CompanionDragRow(start: 0, end: 52, intervals: [300...400])
        XCTAssertTrue(CompanionDragHitTest.shouldDrag(
            point: CGPoint(x: 100, y: 570), in: bounds, strip: 52, rows: [row]))
        XCTAssertFalse(CompanionDragHitTest.shouldDrag(
            point: CGPoint(x: 350, y: 570), in: bounds, strip: 52, rows: [row]))
        XCTAssertFalse(CompanionDragHitTest.shouldDrag(
            point: CGPoint(x: 350, y: 552), in: bounds, strip: 52, rows: [row]))
        let insetRow = CompanionDragRow(start: 0, end: 28, intervals: [])
        XCTAssertTrue(CompanionDragHitTest.shouldDrag(
            point: CGPoint(x: 100, y: 580), in: bounds, strip: 28, rows: [insetRow]))
        XCTAssertFalse(CompanionDragHitTest.shouldDrag(
            point: CGPoint(x: 100, y: 560), in: bounds, strip: 28, rows: [insetRow]))
    }

    func testDoubleClickActionFollowsApplePreference() {
        XCTAssertEqual(CompanionDragHitTest.doubleClickAction("Maximize"), .zoom)
        XCTAssertEqual(CompanionDragHitTest.doubleClickAction("Minimize"), .minimize)
        XCTAssertEqual(CompanionDragHitTest.doubleClickAction("None"), .none)
        XCTAssertEqual(CompanionDragHitTest.doubleClickAction(nil), .zoom)
    }

    func testBridgeShellUsesHiddenInsetTitleBar() {
        XCTAssertEqual(CompanionBridge.shell.kind, "desktop")
        XCTAssertEqual(CompanionBridge.shell.platform, "darwin")
        XCTAssertEqual(CompanionBridge.shell.titleBar, "hidden-inset")
        XCTAssertEqual(CompanionBridge.validate(method: "drag", arguments: []), .invalid)
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





    func testPaceMatchesShopByResourceOrName() {
        let pace = CompanionShopPace(resource: "yunjac.us", name: "YUNJAC.US", currency: "USD",
                                     mtd: 1, goal: 2, expectedByToday: 1, gap: 0,
                                     progressPct: 50, paceStatus: "on_track", basis: "total")
        XCTAssertTrue(CompanionPace.matches(shopResource: "yunjac.us", shopName: "Anything", pace: pace))
        XCTAssertTrue(CompanionPace.matches(shopResource: "YUNJAC.US", shopName: "Anything", pace: pace))
        XCTAssertTrue(CompanionPace.matches(shopResource: "other", shopName: "YUNJAC.US", pace: pace))
        XCTAssertFalse(CompanionPace.matches(shopResource: "other", shopName: "Other", pace: pace))
    }

    func testPaceBarMathsStatusesAndNulls() {
        let base = CompanionShopPace(resource: "north", name: "North Studio", currency: "USD",
                                     mtd: 500, goal: 1000, expectedByToday: 750, gap: -250,
                                     progressPct: 50, paceStatus: "behind", basis: "total")
        let behind = CompanionPaceBarModel(base)
        XCTAssertEqual(behind.actualFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(behind.expectedFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(behind.tone, .red)
        XCTAssertEqual(behind.statusLabel, "Behind")
        XCTAssertTrue(behind.text.contains("expected by today"))

        var onTrack = base
        onTrack = CompanionShopPace(resource: "north", name: "North Studio", currency: "USD",
                                    mtd: 800, goal: 1000, expectedByToday: 750, gap: 50,
                                    progressPct: 80, paceStatus: "on_track", basis: "total")
        XCTAssertEqual(CompanionPaceBarModel(onTrack).tone, .green)
        XCTAssertEqual(CompanionPaceBarModel(onTrack).statusLabel, "On track")

        let ahead = CompanionShopPace(resource: "north", name: "North Studio", currency: "USD",
                                      mtd: 900, goal: 1000, expectedByToday: 700, gap: 200,
                                      progressPct: 90, paceStatus: "ahead", basis: "total")
        XCTAssertEqual(CompanionPaceBarModel(ahead).tone, .green)

        let tooEarly = CompanionShopPace(resource: "north", name: "North Studio", currency: "USD",
                                         mtd: nil, goal: 1000, expectedByToday: nil, gap: nil,
                                         progressPct: nil, paceStatus: "too_early", basis: "total")
        XCTAssertEqual(CompanionPaceBarModel(tooEarly).tone, .grey)
        XCTAssertEqual(CompanionPaceBarModel(tooEarly).statusLabel, "Too early")

        let noTarget = CompanionShopPace(resource: "north", name: "North Studio", currency: "USD",
                                         mtd: 300, goal: nil, expectedByToday: nil, gap: nil,
                                         progressPct: nil, paceStatus: "no_target", basis: "total")
        XCTAssertEqual(CompanionPaceBarModel(noTarget).text, "No target")
        XCTAssertEqual(CompanionPaceBarModel(noTarget).tone, .grey)

        let noData = CompanionShopPace(resource: "north", name: "North Studio", currency: nil,
                                       mtd: nil, goal: 1000, expectedByToday: 600, gap: nil,
                                       progressPct: nil, paceStatus: "no_data", basis: "total")
        XCTAssertEqual(CompanionPaceBarModel(noData).text, "No data")
        XCTAssertEqual(CompanionPaceBarModel(noData).tone, .grey)

        XCTAssertEqual(CompanionPaceState.from(status: 403), .hidden)
        XCTAssertEqual(CompanionPaceState.from(status: 404), .hidden)
        XCTAssertEqual(CompanionPaceState.from(status: 200), .available)
        XCTAssertEqual(CompanionPaceState.from(status: 500), .failed)
    }

    func testPaceParsesPortfolioFixture() throws {
        let json = #"""
        {"as_of":"2026-11-06","month":{"start":"2026-11-01","day":6,"days_in_month":30,"elapsed_pct":20},
         "shops":[
          {"resource":"north","name":"North Studio","metrics_through":"2026-11-06",
           "needs_you":{"total":3},
           "agents":[{"role":"creator manager","on":true},{"role":"ads manager","on":false}],
           "gmv":{"mtd":5000,"currency":"GBP","goal":10000,
            "expected_by_today":6000,"gap":-1000,"progress_pct":50,"pace_status":"behind","basis":"total"}}
         ],"totals":{"shops":1,"behind":1,"gmv_unavailable_shops":0,
           "gmv_by_currency":[{"currency":"GBP","mtd":5000,"goal":10000}]}}
        """#
        let parsed = try XCTUnwrap(CompanionPace.parse(json))
        let north = try XCTUnwrap(parsed.shops["north"])
        XCTAssertEqual(north.currency, "GBP")
        XCTAssertEqual(north.mtd, 5000)
        XCTAssertEqual(north.goal, 10000)
        XCTAssertEqual(north.expectedByToday, 6000)
        XCTAssertEqual(north.paceStatus, "behind")
        XCTAssertEqual(north.metricsThrough, "2026-11-06")
        XCTAssertEqual(north.needsYouTotal, 3)
        XCTAssertEqual(north.agents.map(\.role), ["creator manager", "ads manager"])
        XCTAssertEqual(parsed.metricsThrough, "2026-11-06")
        XCTAssertEqual(parsed.totals?.elapsedPct, 20)
        XCTAssertEqual(parsed.totals?.behind, 1)
        XCTAssertEqual(parsed.totals?.unavailableShops, 0)
        XCTAssertEqual(parsed.totals?.byCurrency.first?.currency, "GBP")
        XCTAssertEqual(parsed.totals?.byCurrency.first?.goal, 10000)
    }

    func testApprovalDecisionBodiesMatchTheWeb() throws {
        let listJSON = #"""
        {"counts":{"pending":1,"mine":1},"shops":[
          {"resource":"north","name":"North Studio","services":[
            {"label":"North agent","items":[
              {"id":"send-1","question":"Approve the reply","version":"v1","send_version":"sv1",
               "can_answer":true,"answers":["approve","change","skip"],"source":"send_approval",
               "kind":"agent_ask","status":"needs_you","age_seconds":60,
               "evidence":[{"label":"Message to send","text":"Hello there"}]}
            ]}
          ]}
        ]}
        """#
        let list = try JSONDecoder().decode(CompanionApprovalsList.self, from: Data(listJSON.utf8))
        let item = try XCTUnwrap(CompanionTodos.make(from: list).shops.first?.items.first)
        XCTAssertEqual(item.payloadPreview, "Hello there")
        let approve = try XCTUnwrap(CompanionDecisionRequests.decisionRequest(item: item, answer: "approve"))
        XCTAssertEqual(approve.path, "/api/oo/approvals/answer")
        XCTAssertEqual(approve.body["answer"] as? String, "approve")
        let rows = try XCTUnwrap(approve.body["items"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["id"] as? String, "send-1")
        XCTAssertEqual(rows.first?["version"] as? String, "v1")
        XCTAssertEqual(rows.first?["send_version"] as? String, "sv1")
        let decline = try XCTUnwrap(CompanionDecisionRequests.decisionRequest(item: item, answer: "skip"))
        XCTAssertEqual(decline.body["answer"] as? String, "skip")

        let shopJSON = #"""
        {"counts":{"pending":1,"mine":1},"shops":[
          {"resource":"north","name":"North Studio","services":[
            {"label":"North agent","items":[
              {"id":"draft-1","question":"Send the draft","age_seconds":30,
               "content_sha256":"hash","draft_kind":"creator_dm","draft_id":42,
               "send_type":"creator_dm","content_clear":true,"can_decide":true,
               "preview":"Hi Dana, here is the sample.","status":"pending"}
            ]}
          ]}
        ]}
        """#
        let shopList = try JSONDecoder().decode(CompanionApprovalsList.self, from: Data(shopJSON.utf8))
        let shopItem = try XCTUnwrap(CompanionTodos.make(from: shopList).shops.first?.items.first)
        XCTAssertEqual(shopItem.answers, ["approve", "skip"])
        let shopApprove = try XCTUnwrap(CompanionDecisionRequests.decisionRequest(item: shopItem, answer: "approve"))
        XCTAssertEqual(shopApprove.path, "/api/oo/shops/north/companion/approvals")
        XCTAssertEqual(shopApprove.body["draft_kind"] as? String, "creator_dm")
        XCTAssertEqual(shopApprove.body["draft_id"] as? Int, 42)
        XCTAssertEqual(shopApprove.body["send_type"] as? String, "creator_dm")
        XCTAssertEqual(shopApprove.body["content_sha256"] as? String, "hash")
        XCTAssertEqual(shopApprove.body["decision"] as? String, "approved")
        let shopDecline = try XCTUnwrap(CompanionDecisionRequests.decisionRequest(item: shopItem, answer: "skip"))
        XCTAssertEqual(shopDecline.body["decision"] as? String, "refused")
    }

    func testApprovalDisabledReasonAndOutcomes() throws {
        let disabledJSON = #"""
        {"counts":{"pending":1,"mine":1},"shops":[
          {"resource":"north","name":"North Studio","services":[
            {"label":"North agent","items":[
              {"id":"draft-2","question":"Empty draft","content_sha256":"hash","draft_kind":"creator_dm",
               "draft_id":43,"send_type":"creator_dm","content_clear":false,"can_decide":true,"preview":""}
            ]}
          ]}
        ]}
        """#
        let list = try JSONDecoder().decode(CompanionApprovalsList.self, from: Data(disabledJSON.utf8))
        let item = try XCTUnwrap(CompanionTodos.make(from: list).shops.first?.items.first)
        XCTAssertEqual(item.disabledReason, "This reply has nothing to send. Skip it or ask for a change.")

        let ok = CompanionFetchReply(status: 200, contentType: "application/json",
                                     body: #"{"results":[{"id":"send-1","status":"ok","message":"Sent"}]}"#, url: "")
        XCTAssertEqual(CompanionDecisionOutcomeParser.outcome(api: .answers, itemId: "send-1",
                                                              answer: "approve", reply: ok),
                       CompanionDecisionOutcome(message: "Sent", remove: true))
        let failed = CompanionFetchReply(status: 200, contentType: "application/json",
                                        body: #"{"results":[{"id":"send-1","status":"failed","message":"Nope"}]}"#, url: "")
        XCTAssertEqual(CompanionDecisionOutcomeParser.outcome(api: .answers, itemId: "send-1",
                                                              answer: "approve", reply: failed),
                       CompanionDecisionOutcome(message: "Nope", remove: false))
        let shopOK = CompanionFetchReply(status: 200, contentType: "application/json", body: "{}", url: "")
        XCTAssertEqual(CompanionDecisionOutcomeParser.outcome(api: .shop, itemId: "draft-1",
                                                              answer: "approve", reply: shopOK),
                       CompanionDecisionOutcome(message: "Approved", remove: true))
        let shopError = CompanionFetchReply(status: 422, contentType: "application/json",
                                           body: #"{"message":"Stale draft"}"#, url: "")
        XCTAssertEqual(CompanionDecisionOutcomeParser.outcome(api: .shop, itemId: "draft-1",
                                                              answer: "approve", reply: shopError),
                       CompanionDecisionOutcome(message: "Stale draft", remove: false))
    }

    func testApprovalsTodoGroupingOrderingAndTruncation() throws {
        let json = #"""
        {
          "counts": {"pending": 7, "mine": 5},
          "order": ["b", "a", "c", "d", "e", "f", "g"],
          "shops": [
            {"resource": "north", "name": "North Studio", "services": [
              {"label": "North agent", "items": [
                {"id": "a", "question": "Approve reorder", "age_seconds": 120, "agent": {"label": "North agent"}},
                {"id": "b", "question": "Book courier", "age_seconds": 30, "agent": {"label": "North agent"}},
                {"id": "c", "question": "Check stock", "age_seconds": 3600},
                {"id": "d", "question": "Reply to buyer", "age_seconds": 86400},
                {"id": "e", "question": "Send samples", "age_seconds": 90000},
                {"id": "f", "question": "Update price", "age_seconds": 0}
              ]}
            ]},
            {"resource": "harbor", "name": "Harbor & Co", "services": [
              {"label": "Harbor agent", "items": [
                {"id": "g", "question": "Pause collection", "age_seconds": 7200}
              ]}
            ]}
          ]
        }
        """#
        let list = try JSONDecoder().decode(CompanionApprovalsList.self, from: Data(json.utf8))
        let snapshot = CompanionTodos.make(from: list)
        XCTAssertEqual(snapshot.total, 7)
        XCTAssertEqual(snapshot.shops.map(\.name), ["North Studio", "Harbor & Co"])
        XCTAssertEqual(snapshot.shops[0].pending, 6)
        XCTAssertEqual(snapshot.shops[0].items.map(\.id), ["b", "a", "c", "d", "e"])
        XCTAssertEqual(snapshot.shops[0].more, 1)
        XCTAssertEqual(snapshot.shops[0].items.map(\.age), ["now", "2m", "1h", "1d", "1d"])
        XCTAssertEqual(snapshot.shops[0].items.first?.clickPath, "/companion/app/north/approvals")
        XCTAssertEqual(snapshot.shops[1].items.map(\.id), ["g"])
        XCTAssertEqual(snapshot.shops[1].items.first?.clickPath, "/companion/app/harbor/approvals")
    }

    func testApprovalsTodoStates() {
        let empty = CompanionTodoSnapshot(total: 0, shops: [], orderedItems: [])
        XCTAssertTrue(CompanionTodosState.ready(empty).showsEmpty)
        XCTAssertTrue(CompanionTodosState.failed.showsError)
        XCTAssertTrue(CompanionTodosState.signedOut.showsSignedOut)
        XCTAssertFalse(CompanionTodosState.loading.showsEmpty)
    }


    func testActivityParsingKeepsNewestFirstAndWaiting() {
        let shop = #"""
        {"tabs":[
          {"agent":"agent-a","name":"North agent","role":"creator-manager","state":"working",
           "now":{"source":"run","kind":"run","label":"Checking orders","since":"2026-11-06T07:00:00Z",
                  "step":{"text":"Reading shop orders","at":"2026-11-06T07:01:00Z","is_error":false}},
           "waiting":null,"last_run":null},
          {"agent":"agent-b","name":"Print agent","role":"printer","state":"waiting","now":null,
           "waiting":{"code":"approval","label":"Waiting for approval","since":"2026-11-06T06:00:00Z"},
           "last_run":{"state":"ok","at":"2026-11-06T05:00:00Z"}}
        ]}
        """#
        let events = #"""
        {"events":[
          {"at":"2026-11-06T07:00:00Z","text":"line older"},
          {"at":"2026-11-06T07:02:00Z","text":"line newest"},
          {"at":"2026-11-06T06:58:00Z","text":"line oldest"},
          {"at":"2026-11-06T06:57:00Z","text":"line beyond"}
        ]}
        """#
        let load = CompanionActivityParser.parse(
            shopStatus: 200, shopBody: shop, eventBodies: ["agent-a": events])
        guard case .ready(let agents) = load else { return XCTFail("expected ready") }
        XCTAssertEqual(agents.map(\.id), ["agent-a", "agent-b"])
        XCTAssertEqual(agents[0].current, "Reading shop orders")
        XCTAssertEqual(agents[0].since, "2026-11-06T07:00:00Z")
        XCTAssertEqual(agents[0].lines, ["line newest", "line older", "line oldest"])
        XCTAssertEqual(agents[1].waiting, "Waiting for approval")
        XCTAssertEqual(agents[1].current, "Waiting for approval")
    }

    func testActivity404HidesAndOtherFailureShowsError() {
        XCTAssertEqual(CompanionActivityAvailability.from(status: 404), .unavailable)
        XCTAssertEqual(CompanionActivityAvailability.from(status: 200), .available)
        XCTAssertEqual(CompanionActivityParser.parse(shopStatus: 404, shopBody: nil, eventBodies: [:]),
                       .unavailable)
        XCTAssertEqual(CompanionActivityParser.parse(shopStatus: 500, shopBody: nil, eventBodies: [:]),
                       .failed)
        XCTAssertTrue(CompanionActivityState.failed.showsError)
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

    func testNavigationAllowsOnlyTheOriginAndExactAuthRoutes() {
        let base = URL(string: "http://100.113.131.96:8090")!
        let policy = CompanionNavigationPolicy(baseURL: base)

        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8090/companion/app/abc")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8090/outlandish/sign-in")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://outlandish.com/sign-in")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "https://evil.larksuite.com/accounts/page/login")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "https://accounts.larksuite.com/accounts/page/login")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://open.larksuite.com/open-apis/authen/v1/authorize")!), .allow)
        XCTAssertEqual(policy.decision(for: URL(string: "https://open.larksuite.com/open-apis/authen/v1/index")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "about:blank")!), .allow)
    }

    func testNavigationSendsOtherLinksToTheBrowser() {
        let policy = CompanionNavigationPolicy(baseURL: URL(string: "http://100.113.131.96:8090")!)

        XCTAssertEqual(policy.decision(for: URL(string: "https://example.com/report")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "http://100.113.131.96:8091/companion")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "https://notoutlandish.com/login")!), .external)
        XCTAssertEqual(policy.decision(for: URL(string: "mailto:help@example.com")!), .external)
        XCTAssertEqual(CompanionNavigationPolicy.externalURL(URL(string: "file:///etc/passwd")!), nil)
        XCTAssertEqual(CompanionNavigationPolicy.externalURL(URL(string: "smb://host/share")!), nil)
        XCTAssertEqual(CompanionNavigationPolicy.externalURL(URL(string: "ollie://chat/x")!), nil)
        XCTAssertNotNil(CompanionNavigationPolicy.externalURL(URL(string: "https://example.com")!))
        XCTAssertNotNil(CompanionNavigationPolicy.externalURL(URL(string: "mailto:help@example.com")!))
    }

    func testDownloadNamesAndBadDragRowsAreRejected() {
        XCTAssertEqual(CompanionWindowController.safeDownloadName("../../invoice.pdf"), "invoice.pdf")
        XCTAssertEqual(CompanionWindowController.safeDownloadName(".hidden.pdf"), "hidden.pdf")
        XCTAssertEqual(CompanionWindowController.safeDownloadName("payload.command"), "")
        XCTAssertEqual(CompanionWindowController.safeDownloadName("payload.APP"), "")
        let rows = CompanionDragHitTest.rows(from: [
            ["start": 0, "end": 10, "intervals": [[0, 10], [20, 30]]],
            ["start": 20, "end": 10, "intervals": [[0, 10]]],
            ["start": Double.nan, "end": 10, "intervals": []],
            ["start": 10, "end": 20, "intervals": [[30, 20], [40, 50]]]
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].intervals.count, 2)
        XCTAssertEqual(rows[1].intervals, [40...50])
    }

    @MainActor func testLarkPopupsRespectPreferencePaneAndPermanentMute() {
        let store = Store()
        let chat = Chat(id: "alerts", name: "App Error Alerts", avatar: nil,
                        isP2P: false, isTopic: false, detail: "", link: nil)
        store.isExpanded = true
        store.settings.showLarkPopups = false
        store.ollieOpen = false
        store.pushToast(chat: chat, text: "RuntimeException")
        XCTAssertTrue(store.toasts.isEmpty)
        XCTAssertNil(store.bubble)

        store.settings.showLarkPopups = true
        store.ollieOpen = true
        XCTAssertFalse(store.showsLarkSurface)
        store.pushToast(chat: chat, text: "RuntimeException")
        XCTAssertTrue(store.toasts.isEmpty, "a Lark toast must not cover the Ollie pane")

        store.ollieOpen = false
        XCTAssertTrue(store.showsLarkSurface)
        store.pushToast(chat: chat, text: "RuntimeException")
        XCTAssertEqual(store.toasts.count, 1)

        store.toasts = []
        store.muteForever(chat)
        XCTAssertTrue(store.isMuted(chat))
        store.pushToast(chat: chat, text: "RuntimeException")
        XCTAssertTrue(store.toasts.isEmpty, "a permanent mute suppresses the toast")
        XCTAssertNil(store.bubble)
        store.unmute(chat)
    }


    func testObserverBagRetainsRegistrationBeyondTheCreatingScope() {
        let center = NotificationCenter()
        let bag = QueryObserverBag(center: center)
        var hits = 0
        do {
            bag.observe(Notification.Name("ollie-test-query")) { _ in hits += 1 }
        }
        center.post(name: Notification.Name("ollie-test-query"), object: nil)
        XCTAssertEqual(hits, 1)
    }

}
