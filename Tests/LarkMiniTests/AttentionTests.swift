import XCTest
@testable import LarkMini

final class AttentionTests: XCTestCase {
    @MainActor
    func testNotificationSuppression() {
        for enabled in [false, true] {
            for focused in [false, true] {
                for duplicate in [false, true] {
                    XCTAssertEqual(Notifications.shouldPost(enabled: enabled, focused: focused, duplicate: duplicate),
                                   enabled && !focused && !duplicate)
                }
            }
        }
    }

    func testWidthHasOneRangeAndLegacySettingsStillDecode() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{\"panelWidth\":380}".utf8))
        XCTAssertEqual(Settings.validWidth(settings.panelWidth), 400)
        XCTAssertEqual(Settings.validWidth(900), 480)
        XCTAssertEqual(Settings.validWidth(.nan), 400)
        XCTAssertEqual(Settings().panelWidth, 400)
    }
}

final class ReplyLayoutTests: XCTestCase {
    func testReplyKeepsParagraphsListsAndCodeWithoutDeletingDetails() {
        let blocks = ReplyBlock.parse("## Ready\n\nUse **this** [link](https://example.com/a).\n\n- First\n2. Next\n\n```sh\nprintf 'x'\n\n# stays code\n```")
        XCTAssertEqual(blocks.map(\.kind), [.heading, .paragraph, .bullet, .bullet, .code])
        XCTAssertEqual(blocks[1].text, "Use **this** [link](https://example.com/a).")
        XCTAssertEqual(blocks[2].marker, "•")
        XCTAssertEqual(blocks[3].marker, "2.")
        XCTAssertEqual(blocks[4].text, "printf 'x'\n\n# stays code")
    }
}

final class MessageGroupingTests: XCTestCase {
    private func message(_ time: Int64, sender: String = "a", mine: Bool = false, type: String = "text") -> ChatMessage {
        ChatMessage(id: "m\(time)", chatId: "chat", type: type, text: "hello", ts: time,
                    sender: Sender(id: sender, name: sender, isMe: mine), imageKey: nil,
                    fileKey: nil, fileName: nil, deleted: false)
    }

    func testOnlyAdjacentSameSenderSameMinuteMessagesGroup() {
        XCTAssertTrue(message(60_001).groups(with: message(119_999)))
        XCTAssertFalse(message(119_999).groups(with: message(120_000)))
        XCTAssertFalse(message(60_001).groups(with: message(60_002, sender: "b")))
        XCTAssertFalse(message(60_001).groups(with: message(60_002, mine: true)))
        XCTAssertFalse(message(60_001).groups(with: message(60_002, type: "system")))
        XCTAssertFalse(message(60_001).groups(with: nil))
    }
}

final class PanelPositionTests: XCTestCase {
    func testDragClampsToVisibleScreenAndHandlesRemovedSmallScreen() {
        let screen = NSRect(x: 100, y: 200, width: 800, height: 600)
        let clamped = PanelGeometry.clamp(NSRect(x: -500, y: 900, width: 400, height: 560), in: screen, margin: 12)
        XCTAssertEqual(clamped, NSRect(x: 112, y: 228, width: 400, height: 560))
        let small = PanelGeometry.clamp(NSRect(x: 1000, y: -50, width: 400, height: 560),
                                        in: NSRect(x: 0, y: 0, width: 320, height: 400), margin: 10)
        XCTAssertEqual(small, NSRect(x: 10, y: 10, width: 300, height: 380))
    }

    func testDroppingAgainstTheRightEdgeDocksAgain() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
        XCTAssertTrue(PanelGeometry.docks(NSRect(x: 1100, y: 117, width: 400, height: 560), in: screen, margin: 12))
        XCTAssertTrue(PanelGeometry.docks(NSRect(x: 1055, y: 300, width: 400, height: 560), in: screen, margin: 12))
        XCTAssertFalse(PanelGeometry.docks(NSRect(x: 342, y: 117, width: 400, height: 560), in: screen, margin: 12))
    }

    func testShowInControlsHeadAndMenuBarAndDefaultsToMenuBar() throws {
        XCTAssertEqual(Settings().showIn, .menubar)
        XCTAssertFalse(ShowIn.menubar.showsEdgeHead)
        XCTAssertTrue(ShowIn.menubar.showsMenuBar)
        XCTAssertTrue(ShowIn.edge.showsEdgeHead)
        XCTAssertFalse(ShowIn.edge.showsMenuBar)
        XCTAssertTrue(ShowIn.both.showsEdgeHead)
        XCTAssertTrue(ShowIn.both.showsMenuBar)
        let legacy = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.showIn, .menubar)
    }

    func testMenuBarPanelAnchorsUnderTheStatusItemAndClampsOnSmallScreens() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let anchor = NSRect(x: 800, y: 875, width: 24, height: 24)
        let panel = PanelGeometry.underStatusItem(size: NSSize(width: 400, height: 560),
                                                  anchor: anchor, in: screen, margin: 12)
        XCTAssertEqual(panel, NSRect(x: 612, y: 303, width: 400, height: 560))

        let small = NSRect(x: 0, y: 0, width: 500, height: 300)
        let smallAnchor = NSRect(x: 450, y: 300, width: 20, height: 20)
        let clamped = PanelGeometry.underStatusItem(size: NSSize(width: 400, height: 560),
                                                    anchor: smallAnchor, in: small, margin: 12)
        XCTAssertEqual(clamped, NSRect(x: 88, y: 12, width: 400, height: 276))
    }


    func testMenuBarPanelFitsContentUpToTheVisibleMaximum() {
        XCTAssertEqual(PanelGeometry.menuBarHeight(contentHeight: 220, visibleHeight: 992), 360)
        XCTAssertEqual(PanelGeometry.menuBarHeight(contentHeight: 600, visibleHeight: 992), 600)
        XCTAssertEqual(PanelGeometry.menuBarHeight(contentHeight: 900, visibleHeight: 992), 760)
        XCTAssertEqual(PanelGeometry.menuBarHeight(contentHeight: 900, visibleHeight: 400), 320)
    }


    func testOpenPanelSitsAboveNormalAndClosedMenuBarDoesNot() {
        let open = PanelLevel.level(isExpanded: true, showIn: .menubar)
        XCTAssertGreaterThanOrEqual(open.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertGreaterThan(open.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertEqual(PanelLevel.level(isExpanded: false, showIn: .menubar).rawValue,
                       NSWindow.Level.normal.rawValue)
        XCTAssertGreaterThan(PanelLevel.level(isExpanded: false, showIn: .edge).rawValue,
                             NSWindow.Level.normal.rawValue)
        let base: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        XCTAssertFalse(PanelLevel.styleMask(isExpanded: true, base: base).contains(.nonactivatingPanel))
        XCTAssertTrue(PanelLevel.styleMask(isExpanded: false, base: base).contains(.nonactivatingPanel))
    }

}
