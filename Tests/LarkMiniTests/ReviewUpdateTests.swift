import XCTest
import JavaScriptCore
@testable import LarkMini

final class ReviewUpdateTests: XCTestCase {
    func testInjectedEditingGuardRetainsDraftAcrossBlurAndRejectedSubmit() throws {
        let context = try guardContext()
        func busy(_ code: String) -> Bool {
            context.evaluateScript(code + "; tick(); messages[messages.length - 1]").toBool()
        }
        XCTAssertFalse(busy(""))
        XCTAssertTrue(busy("document.activeElement = editor"))
        XCTAssertFalse(busy("document.focused = false"))
        XCTAssertTrue(busy("document.focused = true"))
        XCTAssertTrue(busy("editor.value = 'draft'; fire('input', editor); document.activeElement = null; document.focused = false"))
        XCTAssertTrue(busy("fire('submit', form, true)"))
        XCTAssertFalse(busy("fire('reset', form, false)"))
        XCTAssertTrue(busy("editor.value = 'another draft'; fire('input', editor)"))
        XCTAssertFalse(busy("editor.value = ''")) // React clears the controlled composer after send.
        XCTAssertTrue(busy("editor.isContentEditable = true; editor.textContent = 'rich draft'; fire('input', editor)"))
        XCTAssertFalse(busy("fire('submit', form, false)"))
        XCTAssertTrue(busy("fire('input', editor)"))
        XCTAssertFalse(busy("editor.isConnected = false")) // Inline Change editor was closed.
        XCTAssertTrue(context.evaluateScript("messages.every(value => typeof value === 'boolean')").toBool())
        XCTAssertNil(context.exception)
    }

    private func guardContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var messages = [], handlers = {}, tick = () => {};
        var window = this;
        window.webkit = {messageHandlers: {ollieUpdateGuard: {postMessage: value => messages.push(value)}}};
        window.fetch = () => Promise.resolve({});
        var document = {activeElement: null, documentElement: {}, focused: true,
          hasFocus: function() { return this.focused; },
          querySelectorAll: () => [],
          addEventListener: (name, fn) => (handlers[name] ||= []).push(fn)};
        window.addEventListener = (name, fn) => (handlers[name] ||= []).push(fn);
        var queueMicrotask = fn => fn();
        var setInterval = fn => { tick = fn; };
        var MutationObserver = class { constructor(fn) {} observe() {} };
        var XMLHttpRequest = class { open() {} send() {} };
        var editor = {value: '', textContent: '', isContentEditable: false, isConnected: true,
          closest: function() { return this; }};
        var form = {contains: node => node === editor};
        var fire = (name, target, defaultPrevented = false) =>
          (handlers[name] || []).forEach(fn => fn({target, defaultPrevented}));
        """)
        context.evaluateScript(CompanionUpdateGuard.source)
        context.evaluateScript("fire('DOMContentLoaded', document)")
        XCTAssertNil(context.exception)
        return context
    }

    func testRestoresExactSameOriginURL() {
        let base = URL(string: "https://example.com")!
        let exact = "https://example.com/companion/app/chat?thread=example%2Fthread#draft"
        XCTAssertEqual(CompanionRestore.url(exact, base: base)?.absoluteString, exact)
        XCTAssertEqual(CompanionRestore.url("https://example.com/ops/item?id=123", base: base)?.path, "/ops/item")
        for invalid in ["https://elsewhere.example/", "http://example.com/", "https://user:password@example.com/", "/companion/app"] {
            XCTAssertNil(CompanionRestore.url(invalid, base: base))
        }
        XCTAssertNil(CompanionRestore.url(nil, base: base))
    }

    func testConfirmationTracksDecisionContentsNotPollMetadata() throws {
        func item(_ values: [String: Any]) throws -> CompanionTodoItem {
            var object: [String: Any] = ["id": "decision", "source": "send_approval", "can_answer": true,
                "answers": ["approve", "skip"], "version": "v1", "send_version": "s1",
                "evidence": [["label": "Message to send", "text": "Draft"], ["label": "Recipient", "text": "Person"]]]
            object.merge(values, uniquingKeysWith: { _, newer in newer })
            let decoded = try JSONDecoder().decode(CompanionApprovalsList.Item.self, from: JSONSerialization.data(withJSONObject: object))
            let list = CompanionApprovalsList(shops: [.init(resource: "shop", name: "Shop",
                services: [.init(role: nil, label: "Agent", items: [decoded])])], order: nil, counts: nil)
            return try XCTUnwrap(CompanionTodos.make(from: list).orderedItems.first)
        }
        let original = try item([:]).confirmationTarget
        XCTAssertEqual(original, try item(["age_seconds": 600, "status_reason": "Waiting 10 min"]).confirmationTarget)
        for change: [String: Any] in [["id": "new"], ["version": "v2"], ["send_version": "s2"], ["answers": ["skip"]],
            ["evidence": [["label": "Message to send", "text": "Changed"], ["label": "Recipient", "text": "Person"]]],
            ["evidence": [["label": "Message to send", "text": "Draft"], ["label": "Recipient", "text": "Other"]]]] {
            XCTAssertNotEqual(original, try item(change).confirmationTarget)
        }
    }

    @MainActor func testBlockedUpdateExplainsWhy() {
        XCTAssertEqual(OllieUpdates.refusal(companionBusy: true, decisionInFlight: false, confirmationOpen: false),
                       "Finish or close what you're editing in Companion first")
        XCTAssertNotNil(OllieUpdates.refusal(companionBusy: false, decisionInFlight: true, confirmationOpen: false))
        XCTAssertNotNil(OllieUpdates.refusal(companionBusy: false, decisionInFlight: false, confirmationOpen: true))
        XCTAssertNil(OllieUpdates.refusal(companionBusy: false, decisionInFlight: false, confirmationOpen: false))
    }

    func testLarkSessionRefusalAndEmptyAreDistinct() {
        XCTAssertEqual(CompanionLarkState.from(nil, sessionMissing: true), .signedOut)
        for status in [401, 419] {
            XCTAssertEqual(CompanionLarkState.from(.init(status: status, contentType: "", body: "", url: "")), .signedOut)
        }
        XCTAssertEqual(CompanionLarkState.from(.init(status: 403, contentType: "", body: "", url: "")), .unavailable)
        XCTAssertEqual(CompanionLarkState.from(.init(status: 200, contentType: "application/json",
            body: #"{"readOnly":true,"source":{"state":"connected"},"data":[]}"#, url: "")), .ready([]))
        XCTAssertNotEqual(CompanionLarkState.loading, .ready([]))
    }
}
