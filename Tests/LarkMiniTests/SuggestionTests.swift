import XCTest
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
        XCTAssertEqual(draft.yes, .post(path: "/api/oo/shops/res%2F1/strategy-manager/statements",
                                        body: ["text": "GMV $26,000 this month."]))
        XCTAssertEqual(draft.notNow, .post(path: "/api/oo/shops/res%2F1/strategy-manager/recommendations/statement_draft:2026-11-01/dismiss", body: [:]))
        let rec = list[1]
        XCTAssertEqual(rec.text, "I think we should lower the November GMV target to $25,000.")
        XCTAssertEqual(rec.yesLabel, "Hand to Sian")
        XCTAssertEqual(rec.doneText, "Handed to Sian")
        XCTAssertEqual(rec.yes, .post(path: "/api/oo/shops/res%2F1/strategy-manager/recommendations/lower_gmv_target:2026-11:25000/apply", body: [:]))
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
        let snapshot = CompanionTodoSnapshot(total: 4, shops: [], orderedItems: [ok, notMine, send, noRec])
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
    }

    private func item(id: String, mine: Bool, source: String = "agent_ask",
                      recommendationAnswer: String? = "approve") -> CompanionTodoItem {
        CompanionTodoItem(
            id: id, label: "Creator Manager", title: "Approve 12 sample requests?", age: "1h",
            clickPath: "/companion/app", answers: ["approve", "skip"], canAnswer: true, recipients: [],
            canApprove: true, payloadPreview: nil,
            decision: CompanionDecisionTarget(id: id, version: "v1", sendVersion: nil),
            source: source, kind: "", statusReason: nil, needsYouBecause: nil, priorityBand: nil,
            priorityReasons: [], priorityTip: nil, expiresAt: nil, ageSeconds: 3600,
            recommendation: "All fit the brief.", recommendationAnswer: recommendationAnswer,
            assigneeLine: "", decidedReason: nil, itemLink: nil, shopName: "YUNJAC", resource: "r1", mine: mine)
    }
}
