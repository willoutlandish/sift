import XCTest
@testable import LarkMini

final class ApprovalEligibilityTests: XCTestCase {
    func testEligibilityMatrixAndRequestGuard() throws {
        for source in ["send_approval", "creator_dm_reply", "agent_question"] {
            for canAnswer in [false, true] {
                for offered in [false, true] {
                    for version in ["", "bound"] {
                        for draft in ["", "Message"] {
                            for count in 0...2 {
                                let evidence = [["label": "Message to send", "text": draft]] +
                                    (0..<count).map { ["label": "Recipient", "text": "Person \($0)"] }
                                let object: [String: Any] = ["id": "a", "source": source,
                                    "can_answer": canAnswer, "answers": offered ? ["approve", "skip"] : ["skip"],
                                    "send_version": version, "evidence": evidence]
                                let item = try JSONDecoder().decode(CompanionApprovalsList.Item.self,
                                    from: JSONSerialization.data(withJSONObject: object))
                                let expected = canAnswer && offered && count <= 1 &&
                                    (source == "agent_question" || (!version.isEmpty && !draft.isEmpty && count == 1))
                                XCTAssertEqual(CompanionApprovalEligibility.canApprove(item), expected,
                                    "\(source) \(canAnswer) \(offered) \(version) \(draft) \(count)")
                                let list = CompanionApprovalsList(shops: [.init(resource: "shop", name: "Shop",
                                    services: [.init(role: nil, label: "Agent", items: [item])])], order: nil, counts: nil)
                                let todo = try XCTUnwrap(CompanionTodos.make(from: list).orderedItems.first)
                                XCTAssertEqual(CompanionDecisionRequests.decisionRequest(item: todo, answer: "approve") != nil, expected)
                                XCTAssertNil(CompanionDecisionRequests.decisionRequest(item: todo, answer: "unoffered"))
                            }
                        }
                    }
                }
            }
        }
    }

    func testEvidenceLabelsAndFirstDraftMatchBoard() throws {
        let json = #"{"id":"a","evidence":[{"label":"recipient","text":"ignored"},{"label":"To","text":""},{"label":"Recipient","text":"A"},{"label":"Message to send","text":""},{"label":"Message to send","text":"later"}]}"#
        let item = try JSONDecoder().decode(CompanionApprovalsList.Item.self, from: Data(json.utf8))
        XCTAssertEqual(CompanionApprovalEligibility.recipientsOf(item), ["A"])
        XCTAssertEqual(CompanionApprovalEligibility.draftText(item), "")
    }
}
