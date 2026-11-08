import XCTest
import AppKit
import JavaScriptCore
@testable import LarkMini

final class CompanionPresentationTests: XCTestCase {
    func testUserEntryPointsRevealOnActiveSpace() {
        for source: CompanionOpenSource in [.panel, .dock, .cli, .notification] {
            XCTAssertTrue(source.requestsForeground, "\(source)")
            XCTAssertTrue(source.collectionBehavior.contains(.moveToActiveSpace), "\(source)")
            XCTAssertTrue(source.collectionBehavior.contains(.fullScreenAuxiliary), "\(source)")
            XCTAssertFalse(source.collectionBehavior.contains(.canJoinAllSpaces), "\(source)")
        }
        for source: CompanionOpenSource in [.urlScheme, .updateRestore] {
            XCTAssertFalse(source.requestsForeground, "\(source)")
            XCTAssertFalse(source.collectionBehavior.contains(.moveToActiveSpace), "\(source)")
        }
    }

    func testNonBridgeInsetWaitsForBodyPreservesPaddingAndDoesNotTransformHTML() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var writes = [], ready;
        var window = {getComputedStyle: () => ({paddingTop: '16px'})};
        var document = {body: null, readyState: 'loading',
          documentElement: {style: {setProperty: () => { throw Error('root changed'); }}},
          addEventListener: (name, fn) => { if (name === 'DOMContentLoaded') ready = fn; }};
        """)
        context.evaluateScript(CompanionPageInset.source)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("writes.length").toInt32(), 0)
        context.evaluateScript("""
        document.body = {dataset: {}, style: {setProperty: (...args) => writes.push(args)}};
        document.readyState = 'complete'; ready();
        """)
        context.evaluateScript(CompanionPageInset.source) // Reapplying must not double the inset.
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(writes)").toString(),
                       #"[["padding-top","calc(16px + 28px)","important"]]"#)
    }

    func testNonBridgeSignInControlsAlwaysReachWebKitWithoutDragMap() {
        let bounds = CGRect(x: 0, y: 0, width: 980, height: 720)
        // A link or fixed-position button must work even inside the native inset,
        // before asynchronous DOM sampling, and on a different auth origin.
        for top in [0.0, 14, 28, 150, 360] {
            XCTAssertFalse(CompanionDragHitTest.shouldDrag(
                point: CGPoint(x: 400, y: 720 - top), in: bounds,
                strip: CompanionDragHitTest.insetTitleBarHeight, rows: [], isCompanionPage: false))
        }
        // The same blank titlebar area on the actual Companion app still drags.
        XCTAssertTrue(CompanionDragHitTest.shouldDrag(
            point: CGPoint(x: 400, y: 700), in: bounds,
            strip: CompanionDragHitTest.titleBarHeight, rows: [], isCompanionPage: true))
    }

    func testOutlandishIDLinkAndProviderStayInCompanion() {
        let base = URL(string: "https://outlandishteam.com")!
        let policy = CompanionNavigationPolicy(baseURL: base)
        let signIn = base.appendingPathComponent("outlandish/sign-in")
        let authorize = base.appendingPathComponent("outlandish/authorize")
        XCTAssertEqual(policy.decision(for: signIn), .allow)
        XCTAssertEqual(policy.decision(for: authorize), .allow)
        XCTAssertEqual(policy.windowOpenDecision(for: authorize, topURL: signIn), .loadInCompanion)
        XCTAssertEqual(policy.decision(for: URL(string: "https://api.workos.com/user_management/authorize")!), .allow)
    }
}
