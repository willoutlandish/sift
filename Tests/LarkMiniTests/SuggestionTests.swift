import XCTest
import SwiftUI
import AppKit
@testable import LarkMini

final class SuggestionTests: XCTestCase {
    private let strategyBody = #"""
    {"agent":{"principal":"p1","name":"Strategy Manager","role":"strategy-manager"},
     "month":"November","period":"2026-11-01",
     "draft":{"display":"For YUNJAC this month, I'd recommend GMV $26,000 (projecting this month's pace through 7 Nov).","apply_text":"GMV $26,000 this month."},
     "check":{"recommendations":[
        {"key":"lower_gmv_target:2026-11:25000","title":"Lower the November GMV target to $25,000","reason":"$6,273 in 7 days is 61% of pace.","to_role":"account-manager","to_name":"Sian","via":"ask","handed":null,"dismissed":false},
        {"key":"more_samples:2026-11","title":"Send 20 more samples this week","reason":"r","to_name":"Creator Manager","handed":{"status":"open"},"dismissed":false},
        {"key":"gone","title":"Old idea","dismissed":true,"handed":null},
        {"key":"GMV_first","title":"GMV is behind","dismissed":false}
     ]}}
    """#

    func testStrategyManagerOffersTheDraftAndOnlyOpenRecommendations() {
        let list = OllieSuggestions.strategyManager(strategyBody, resource: "res/1", shop: "YUNJAC")
        XCTAssertEqual(list.map(\.id), ["sm:res/1:draft:2026-11-01:GMV $26,000 this month.",
                                        "sm:res/1:rec:lower_gmv_target:2026-11:25000",
                                        "sm:res/1:rec:GMV_first"])
        let draft = list[0]
        XCTAssertEqual(draft.byline, "Strategy Manager · YUNJAC")
        XCTAssertEqual(draft.yes, .applyDraft(resource: "res/1", applyText: "GMV $26,000 this month."),
                       "the draft is re-read before it is applied, as the in-app card does")
        XCTAssertEqual(draft.notNow, .post(path: "/api/oo/shops/res%2F1/strategy-manager/recommendations/statement_draft%3A2026-11-01/dismiss", body: [:]),
                       "keys are encoded like encodeURIComponent in StrategyManagerOllieCard")
        XCTAssertEqual(OllieSuggestions.currentDraftText(strategyBody), "GMV $26,000 this month.")
        XCTAssertNil(OllieSuggestions.currentDraftText(#"{"agent":{},"draft":null}"#))
        let rec = list[1]
        XCTAssertEqual(rec.text, "I think we should lower the November GMV target to $25,000.")
        XCTAssertEqual(rec.yesLabel, "Yes, do it")
        XCTAssertEqual(rec.doneText, "Handed to Sian")
        XCTAssertEqual(rec.yes, .post(path: "/api/oo/shops/res%2F1/strategy-manager/recommendations/lower_gmv_target%3A2026-11%3A25000/apply", body: [:]))
        XCTAssertEqual(list[2].text, "I think we should GMV is behind.", "acronyms keep their case")
    }

    func testNoStrategyManagerMeansNoSuggestions() {
        XCTAssertTrue(OllieSuggestions.strategyManager(#"{"agent":null,"period":"2026-11-01","draft":{"display":"x","apply_text":"y"}}"#,
                                                        resource: "r", shop: "S").isEmpty)
        XCTAssertTrue(OllieSuggestions.strategyManager("<html>", resource: "r", shop: "S").isEmpty)
    }

    func testOnlyMyOneTapRecommendedApprovalsBecomeSuggestions() {
        let ok = item(id: "a1", mine: true)
        let notMine = item(id: "a2", mine: false)
        let send = item(id: "a3", mine: true, source: "send_approval")
        let noRec = item(id: "a4", mine: true, recommendationAnswer: nil)
        let incentive = item(id: "a5", mine: true, source: "incentive")
        let withRecipient = item(id: "a6", mine: true, recipients: ["Creator A"])
        let snapshot = CompanionTodoSnapshot(total: 6, shops: [], orderedItems: [ok, notMine, send, noRec, incentive, withRecipient])
        let list = OllieSuggestions.approvals(snapshot)
        XCTAssertEqual(list.map(\.id), ["approval:a1:v1"])
        XCTAssertEqual(list[0].agent, "Creator Manager")
        XCTAssertEqual(list[0].yes, .approve(ok))
    }

    func testQueueOffersEachOnceAndRefreshesPerSource() {
        let a = OllieSuggestion(id: "sm:r1:rec:a", agent: "SM", shop: "S", text: "a", yes: .demo("x"))
        let b = OllieSuggestion(id: "sm:r1:rec:b", agent: "SM", shop: "S", text: "b", yes: .demo("x"))
        let c = OllieSuggestion(id: "approval:c:", agent: "CM", shop: "S", text: "c", yes: .demo("x"))
        var queue = OllieSuggestionQueue(handled: ["sm:r1:rec:old"])
        queue.offer([a, b], source: "sm:r1:")
        queue.offer([c], source: "approval:")
        XCTAssertEqual(queue.pending.map(\.id), [a.id, b.id, c.id])
        // The shop's next read no longer has b: it leaves the line; other sources are untouched.
        queue.offer([a], source: "sm:r1:")
        XCTAssertEqual(queue.pending.map(\.id), [a.id, c.id])
        XCTAssertEqual(queue.next()?.id, a.id)
        queue.requeue(a)
        XCTAssertEqual(queue.pending.first?.id, a.id, "an interrupted suggestion goes back to the front")
        queue.markHandled(a.id)
        queue.offer([a], source: "sm:r1:")
        XCTAssertEqual(queue.pending.map(\.id), [c.id], "answered or not-now never comes back")
        queue.offer([b], source: "sm:r1:")
        queue.drop(source: "sm:r1:")
        XCTAssertEqual(queue.pending.map(\.id), [c.id], "a shop that is gone leaves the line")
    }

    func testSuggestionStepsAsideForAChatInsteadOfMerging() {
        let s = OllieSuggestions.demo("strategy")
        let bubble = EdgeBubble(target: .suggestion, title: s.byline, text: s.text, suggestion: s)
        let chat = EdgeBubble.arrival(bubble, chatId: "c1", name: "Sam", text: "Hi")
        XCTAssertEqual(chat.target, .chat("c1"))
        XCTAssertNil(chat.suggestion)
        XCTAssertEqual(chat.title, "Sam")
    }

    func testStrategyShopsPrefersFlaggedShops() {
        func shop(_ name: String, sm: Bool) -> CompanionShopPace {
            CompanionShopPace(resource: name, name: name, currency: nil, mtd: nil, goal: nil, expectedByToday: nil,
                              gap: nil, progressPct: nil, paceStatus: "", basis: nil,
                              agents: sm ? [CompanionPaceAgent(role: "strategy-manager", on: true)] : [])
        }
        XCTAssertEqual(OllieSuggestionCenter.strategyShops([shop("B", sm: false), shop("A", sm: true)]).map(\.name), ["A"])
        XCTAssertEqual(OllieSuggestionCenter.strategyShops([shop("B", sm: false), shop("A", sm: false)]).map(\.name), ["A", "B"],
                       "a small portfolio with no flags is read whole")
        let many = (0..<20).map { shop("S\($0)", sm: false) }
        XCTAssertTrue(OllieSuggestionCenter.strategyShops(many).isEmpty, "a big portfolio only reads flagged shops")
        let flagged = (10..<35).map { shop("S\($0)", sm: true) }
        let pool = OllieSuggestionCenter.strategyShops(flagged)
        XCTAssertEqual(pool.count, 25, "every flagged shop is in the pool")
        let first = OllieSuggestionCenter.strategyBatch(pool, cursor: 0)
        let wrap = OllieSuggestionCenter.strategyBatch(pool, cursor: 20)
        XCTAssertEqual(first.count, 10)
        XCTAssertEqual(wrap.map(\.name), ["S30", "S31", "S32", "S33", "S34", "S10", "S11", "S12", "S13", "S14"],
                       "rounds take turns and wrap, so no shop is starved")
    }

    private func item(id: String, mine: Bool, source: String = "agent_ask",
                      recommendationAnswer: String? = "approve", recipients: [String] = []) -> CompanionTodoItem {
        CompanionTodoItem(
            id: id, label: "Creator Manager", title: "Approve 12 sample requests?", age: "1h",
            clickPath: "/companion/app", answers: ["approve", "skip"], canAnswer: true, recipients: recipients,
            canApprove: true, payloadPreview: nil,
            decision: CompanionDecisionTarget(id: id, version: "v1", sendVersion: nil),
            source: source, kind: "", statusReason: nil, needsYouBecause: nil, priorityBand: nil,
            priorityReasons: [], priorityTip: nil, expiresAt: nil, ageSeconds: 3600,
            recommendation: "All fit the brief.", recommendationAnswer: recommendationAnswer,
            assigneeLine: "", decidedReason: nil, itemLink: nil, shopName: "YUNJAC", resource: "r1", mine: mine)
    }
}

@MainActor
final class SuggestionFeedTests: XCTestCase {
    func testManagementFeedShowsOpenIdeasAndAnswersMoveToHistory() async {
        let center = OllieSuggestionCenter()
        center.seedDemo()
        XCTAssertEqual(center.feed.map(\.agent), ["Strategy Manager", "Creator Manager"])
        let first = center.feed[0]
        await center.notNow(first)
        XCTAssertEqual(center.feed.map(\.agent), ["Creator Manager"])
        XCTAssertEqual(center.history.map(\.outcome), ["Not now"])
        let result = await center.yes(center.feed[0])
        XCTAssertTrue(result.ok)
        XCTAssertTrue(center.feed.isEmpty)
        XCTAssertEqual(center.history.last?.yes, true)
        XCTAssertTrue(center.working.isEmpty)
    }

    func testFailedNotNowKeepsTheIdeaOpenAndResetClearsEverything() async {
        let center = OllieSuggestionCenter()
        center.seedDemo()
        let real = OllieSuggestion(id: "sm:r:rec:k", agent: "Strategy Manager", shop: "S", text: "t",
                                   yes: .demo("x"), notNow: .post(path: "/api/oo/shops/r/strategy-manager/recommendations/k/dismiss", body: [:]))
        // No Companion page loaded in tests, so the dismiss cannot reach the server.
        await center.notNow(real)
        XCTAssertNotNil(center.failures[real.id])
        XCTAssertTrue(center.history.isEmpty, "a failed Not now is not recorded as answered")
        center.reset()
        XCTAssertTrue(center.feed.isEmpty)
        XCTAssertTrue(center.history.isEmpty)
        XCTAssertTrue(center.failures.isEmpty)
    }

    /// Renders the bubble and the Management chat offscreen for a visual check (no window opens).
    func testRenderPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["OLLIE_RENDER_DIR"] else { throw XCTSkip("set OLLIE_RENDER_DIR") }
        let store = Store.demo()
        OllieSuggestionCenter.shared.seedDemo()
        let bubble = SuggestionBubbleView(suggestion: OllieSuggestions.demo("strategy")).environmentObject(store)
            .frame(width: 360, height: 230).background(Color(white: 0.3))
        let chat = ShellView().environmentObject(store).frame(width: 400, height: 640).background(SiftStyle.surface)
        store.showManagement()
        let rows = VStack(alignment: .leading, spacing: 14) {
            ForEach(OllieSuggestionCenter.shared.feed) { SuggestionMessage(suggestion: $0) }
        }.padding(16).frame(width: 340).background(SiftStyle.surface).environmentObject(store)
        for (name, view) in [("bubble", AnyView(bubble)), ("management", AnyView(chat)), ("rows", AnyView(rows))] {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
    }
}
