import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: Store
    private let panelController: PanelController
    private let bubbleController: EdgeBubbleController
    private let demoMode: Bool
    private let backgroundCheck: Bool
    private let showPanelCheck: Bool
    private var statusItem: NSStatusItem?
    private var outsideMonitor: Any?
    private var hotKey: GlobalHotKey?
    private var editMonitor: Any?
    private var keyMonitor: Any?
    private let panelSettingsBag = QueryObserverBag()
    private var queryActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var badgeWatch: AnyCancellable?
    private var companionProbes: [CompanionSignInProbe] = []
    private let companionStatusInstance = UUID().uuidString
    private lazy var companionProbe = CompanionProbeCoordinator(
        cookieCheck: { baseURL, completion in
            CompanionSession.sessionCookieExists(for: baseURL) { exists in
                Task { @MainActor in completion(exists) }
            }
        },
        signInCheck: { [weak self] baseURL, completion in
            guard let self else { completion(false); return }
            let probe = CompanionSignInProbe()
            self.companionProbes.append(probe)
            probe.check(baseURL: baseURL, timeoutAfter: CompanionProbeCoordinator.probeTimeout) { signedIn in
                self.companionProbes.removeAll { $0 === probe }
                completion(signedIn)
            }
        }
    )

    init(demo: Bool, openDemoChat: Bool = false, openDemoControl: Bool = false, openDemoSearch: Bool = false, demoNeedsYou: Bool = false) {
        demoMode = demo
        backgroundCheck = CommandLine.arguments.contains("--background-check")
        showPanelCheck = CommandLine.arguments.contains("--show-panel-check")
        store = demo ? Store.demo(needsYou: demoNeedsYou) : Store()
        if demo && openDemoChat, let chat = store.chats.first { store.open(chat) }
        if demo && openDemoControl { store.controlOpen = true }
        if demo && openDemoSearch {
            store.searchOpen = true
        }
        panelController = PanelController(store: store)
        bubbleController = EdgeBubbleController(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GazeTracker.shared.start()
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: AppPaths.supportDirectory.path)
        SecureResponseFile.purgeStale(in: AppPaths.supportDirectory,
                                      prefixes: ["companion-status-", "companion-pace-",
                                                 "companion-drag-map-", "companion-open-"])
        Notifications.shared.onOpen = { [weak self] destination in
            guard let self else { return }
            self.panelController.expand(fromMenuBar: self.store.settings.showIn == .menubar)
            if destination == "control" {
                self.store.openControl()
            } else if destination.hasPrefix("companion:") {
                self.store.openCompanion(path: String(destination.dropFirst("companion:".count)))
            } else if let chat = self.store.chats.first(where: { $0.id == destination }) {
                self.store.open(chat)
            }
        }
        Task { await Notifications.shared.refresh(request: Notifications.shared.enabled) }
        let queryCenter = DistributedNotificationCenter.default()
        queryCenter.addObserver(self, selector: #selector(companionStatusNote(_:)),
                                name: .companionStatusRequest, object: nil,
                                suspensionBehavior: .deliverImmediately)
        queryCenter.addObserver(self, selector: #selector(companionOpenNote(_:)),
                                name: .companionOpenRequest, object: nil,
                                suspensionBehavior: .deliverImmediately)
        queryCenter.addObserver(self, selector: #selector(companionPaceNote(_:)),
                                name: .companionPaceRequest, object: nil,
                                suspensionBehavior: .deliverImmediately)
        queryCenter.addObserver(self, selector: #selector(companionDragMapNote(_:)),
                                name: .companionDragMapRequest, object: nil,
                                suspensionBehavior: .deliverImmediately)
        queryCenter.addObserver(self, selector: #selector(settingsNote(_:)),
                                name: .appSettingsChanged, object: nil,
                                suspensionBehavior: .deliverImmediately)
        queryActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "Answer local Ollie CLI queries")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CompanionApprovalsMonitor.shared.wake() }
        }
        installEditMenu()
        installKeyMonitor()
        panelController.menuBarAnchor = { [weak self] in self?.statusItemAnchor() }
        OllieBadge.onSet = { [weak self] _, _ in self?.refreshStatusBadge() }
        panelSettingsBag.observe(.panelSettingsChanged) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyShowInMode() }
        }
        applyShowInMode()
        let signedIn: Bool
        if case .signedIn = store.auth { signedIn = true } else { signedIn = false }
        store.isExpanded = demoMode ? !CommandLine.arguments.contains("--demo-needs-you")
            : (!signedIn && store.settings.showIn.showsEdgeHead)
        if !backgroundCheck && store.settings.showIn.showsEdgeHead {
            panelController.show()
        }
        store.start()
        if let raw = store.companionURL, let base = CompanionConfig.validatedURL(raw) {
            CompanionApprovalsMonitor.shared.start(baseURL: base)
        }
        if !demoMode && !backgroundCheck { installOutsideClickMonitor() }
        startBadgeWatch()
        if !backgroundCheck {
            let hotKey = GlobalHotKey { [weak self] in self?.panelController.toggle() }
            hotKey.register()
            self.hotKey = hotKey
        }
        if store.isExpanded && !backgroundCheck {
            panelController.expand()
        }
        Task { @MainActor in self.refreshStatusBadge() }
        if showPanelCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    self.panelController.expand(fromMenuBar: self.store.settings.showIn == .menubar,
                                                activate: true)
                    self.panelController.panel.orderFrontRegardless()
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == AppIdentity.urlScheme, url.host == "companion" {
                let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "path" }?.value
                let raw = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = raw.hasPrefix("/") ? raw : "/" + raw
                guard normalized.hasPrefix("/companion/app") else { return }
                let accepted = CompanionPath.accepted(normalized)
                guard CompanionConfig.isCompanionAppPath(accepted) else { return }
                store.openCompanion(path: accepted, activate: false)
            } else if let id = ChatLinks.chatId(from: url) {
                panelController.expand(fromMenuBar: store.settings.showIn == .menubar)
                store.openLinkedChat(id)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        switch DockRouting.destination(panelOpen: store.isExpanded && panelController.panel.isVisible) {
        case .panel: panelController.expand(fromMenuBar: store.settings.showIn == .menubar)
        case .companion: store.openCompanion()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let queryActivity { ProcessInfo.processInfo.endActivity(queryActivity) }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        let queryCenter = DistributedNotificationCenter.default()
        for name in [Notification.Name.companionStatusRequest, .companionOpenRequest,
                     .companionPaceRequest, .companionDragMapRequest, .appSettingsChanged] {
            queryCenter.removeObserver(self, name: name, object: nil)
        }
    }

    @objc nonisolated private func companionStatusNote(_ note: Notification) {
        AppQueryLog.record("status")
        Task { @MainActor in self.answerCompanionStatus(note) }
    }

    @objc nonisolated private func companionOpenNote(_ note: Notification) {
        AppQueryLog.record("open")
        Task { @MainActor in self.answerCompanionOpen(note) }
    }

    @objc nonisolated private func companionPaceNote(_ note: Notification) {
        AppQueryLog.record("pace")
        Task { @MainActor in self.answerCompanionPace(note) }
    }

    @objc nonisolated private func companionDragMapNote(_ note: Notification) {
        AppQueryLog.record("drag-map")
        Task { @MainActor in self.answerCompanionDragMap(note) }
    }

    @objc nonisolated private func settingsNote(_ note: Notification) {
        AppQueryLog.record("settings")
        Task { @MainActor in
            guard note.userInfo?["home"] as? String == AppPaths.supportDirectory.path else { return }
            self.store.reloadState()
            self.applyShowInMode()
        }
    }

    private func answerCompanionStatus(_ note: Notification) {
        guard AppQueryFreshness.isFresh(note, maxAge: 20), let id = note.userInfo?["id"] as? String, UUID(uuidString: id) != nil,
              note.userInfo?["home"] as? String == AppPaths.supportDirectory.path,
              let requested = (note.userInfo?["url"] as? String).flatMap(CompanionConfig.validatedURL),
              let configured = StateFile.shared.reload().companionURL.flatMap(CompanionConfig.validatedURL),
              requested.absoluteString == configured.absoluteString else { return }
        let instance = companionStatusInstance
        companionProbe.check(baseURL: requested) { result in
            let file = AppPaths.supportDirectory
                .appendingPathComponent("companion-status-\(id)-\(instance).json")
            let payload: [String: Any] = ["signed_in": result.signedIn, "cookie_present": result.cookiePresent]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            SecureResponseFile.write(data, to: file)
        }
    }

    private func answerCompanionDragMap(_ note: Notification) {
        guard AppQueryFreshness.isFresh(note, maxAge: 8), let id = note.userInfo?["id"] as? String, UUID(uuidString: id) != nil,
              note.userInfo?["home"] as? String == AppPaths.supportDirectory.path,
              let requested = (note.userInfo?["url"] as? String).flatMap(CompanionConfig.validatedURL),
              let configured = StateFile.shared.reload().companionURL.flatMap(CompanionConfig.validatedURL),
              requested.absoluteString == configured.absoluteString else { return }
        let instance = companionStatusInstance
        Task { @MainActor in
            var payload = await CompanionWindowController.shared.dragMapPayload()
            payload["ok"] = true
            payload["url"] = requested.absoluteString
            let file = AppPaths.supportDirectory
                .appendingPathComponent("companion-drag-map-\(id)-\(instance).json")
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            SecureResponseFile.write(data, to: file)
        }
    }

    private func answerCompanionPace(_ note: Notification) {
        guard AppQueryFreshness.isFresh(note, maxAge: 24), let id = note.userInfo?["id"] as? String, UUID(uuidString: id) != nil,
              note.userInfo?["home"] as? String == AppPaths.supportDirectory.path,
              let requested = (note.userInfo?["url"] as? String).flatMap(CompanionConfig.validatedURL),
              let configured = StateFile.shared.reload().companionURL.flatMap(CompanionConfig.validatedURL),
              requested.absoluteString == configured.absoluteString else { return }
        let instance = companionStatusInstance
        CompanionApprovalsMonitor.shared.start(baseURL: requested)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let probe = await CompanionApprovalsMonitor.shared.refreshPaceNow()
            let payload: [String: Any] = [
                "status": probe.status,
                "pace_state": probe.paceState.label,
                "shop_count": probe.shops.count,
                "shops": probe.shops.map { shop in
                    ["resource": shop.resource, "name": shop.name,
                     "pace_status": shop.paceStatus, "goal": shop.goal.map { $0 as Any } ?? NSNull()]
                }
            ]
            let file = AppPaths.supportDirectory
                .appendingPathComponent("companion-pace-\(id)-\(instance).json")
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            SecureResponseFile.write(data, to: file)
        }
    }

    private func answerCompanionOpen(_ note: Notification) {
        guard AppQueryFreshness.isFresh(note, maxAge: 4), let id = note.userInfo?["id"] as? String, UUID(uuidString: id) != nil,
              note.userInfo?["home"] as? String == AppPaths.supportDirectory.path,
              let requested = (note.userInfo?["url"] as? String).flatMap(CompanionConfig.validatedURL),
              let configured = StateFile.shared.reload().companionURL.flatMap(CompanionConfig.validatedURL),
              requested.absoluteString == configured.absoluteString,
              let path = note.userInfo?["path"] as? String,
              let target = CompanionConfig.cliTargetURL(base: requested, path: path) else { return }
        let instance = companionStatusInstance
        if !backgroundCheck {
            panelController.expand(fromMenuBar: store.settings.showIn == .menubar)
        }
        CompanionWindowController.shared.open(baseURL: requested, path: path, allowAnyPath: true,
                                              activate: !backgroundCheck)
        let file = AppPaths.supportDirectory
            .appendingPathComponent("companion-open-\(id)-\(instance).json")
        let payload: [String: Any] = ["opened": true, "url": target.absoluteString]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        SecureResponseFile.write(data, to: file)
    }

    /// Accessory apps with no main menu never route ⌘C/⌘V/⌘A, so the panel's
    /// text fields are dead. Install the standard Edit menu and a fallback
    /// monitor for the nonactivating panel.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(AppIdentity.displayName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu

        editMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            let key = event.charactersIgnoringModifiers?.lowercased()
            let selector: Selector?
            switch key {
            case "v": selector = #selector(NSText.paste(_:))
            case "c": selector = #selector(NSText.copy(_:))
            case "x": selector = #selector(NSText.cut(_:))
            case "a": selector = #selector(NSText.selectAll(_:))
            case "z": selector = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: selector = nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: nil) {
                return nil
            }
            return event
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKey(event) == nil }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard store.isExpanded, !store.showingShortcuts else { return event }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if store.searchOpen {
            switch event.keyCode {
            case 125: store.moveSearchSelection(1); return nil
            case 126: store.moveSearchSelection(-1); return nil
            case 36: store.openSelectedSearchResult(); return nil
            default: break
            }
        }

        let typing = (NSApp.keyWindow?.firstResponder as? NSTextView) != nil
        if !store.searchOpen, !typing, flags.isEmpty,
           store.openChat == nil, !store.showingSettings, !store.controlOpen {
            switch event.keyCode {
            case 38, 125: store.moveListSelection(1); return nil   // j, down
            case 40, 126: store.moveListSelection(-1); return nil  // k, up
            case 14: store.markSelectedRead(); return nil     // e
            case 36:
                if let chat = store.selectedInboxChat() {
                    store.open(chat)
                    return nil
                }
            default: break
            }
        }

        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k": store.openSearch(); return nil
            case ",":
                if store.searchOpen { store.closeSearch() }
                store.showingSettings = true
                return nil
            case "0": store.showInbox(); return nil
            default: break
            }
        }

        if flags.contains(.command),
           let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number) {
            let pins = store.pinnedChats
            if number <= pins.count {
                store.open(pins[number - 1])
                return nil
            }
        }

        return event
    }

    private func statusItemAnchor() -> NSRect? {
        guard statusItem != nil, let screen = NSScreen.screens.first else { return nil }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 25,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width > 0, width <= 80, height > 0, height <= 60 else { continue }
            return NSRect(x: x, y: screen.frame.maxY - y - height, width: width, height: height)
        }
        return nil
    }

    private func setUpStatusItem() {
        guard statusItem == nil else {
            refreshStatusBadge()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = BrandIcon.statusBar(unread: OllieBadge.current.unread > 0)
            button.imagePosition = .imageLeft
            button.title = OllieBadge.current.approvals > 0 ? " \(OllieBadge.current.approvals)" : ""
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func applyShowInMode() {
        NSApp.setActivationPolicy(store.settings.showInDock ? .regular : .accessory)
        if store.settings.showIn.showsMenuBar {
            setUpStatusItem()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        refreshStatusBadge()
        panelController.applyMode()
        if store.settings.showIn.showsMenuBar {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                MainActor.assumeIsolated {
                    self?.panelController.applyMode()
                    self?.ensureStatusItemVisible()
                    self?.primeStatusItem()
                }
            }
        }
    }

    private func primeStatusItem() {
        guard let item = statusItem, let window = item.button?.window, window.frame.minY < 0 else { return }
        let trigger = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1, height: 1),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        trigger.isOpaque = false
        trigger.backgroundColor = .clear
        trigger.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            trigger.orderOut(nil)
            guard let self else { return }
            if let current = self.statusItem, let win = current.button?.window, win.frame.minY < 0 {
                NSStatusBar.system.removeStatusItem(current)
                self.statusItem = nil
                self.setUpStatusItem()
            }
        }
    }

    private func ensureStatusItemVisible() {
        guard let item = statusItem, let window = item.button?.window, window.frame.minY < 0 else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        setUpStatusItem()
    }

    private func refreshStatusBadge() {
        let badge = OllieBadge.current
        NSApp.dockTile.badgeLabel = badge.approvals > 0 ? String(badge.approvals) : nil
        guard let button = statusItem?.button else { return }
        button.image = BrandIcon.statusBar(unread: badge.unread > 0)
        button.imagePosition = .imageLeft
        button.title = badge.approvals > 0 ? " \(badge.approvals)" : ""
    }

    private func startBadgeWatch() {
        badgeWatch = store.$chats
            .combineLatest(store.$previews, store.$lastSeen, store.$muted)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUnreadBadge() }
            }
        refreshUnreadBadge()
    }

    private func refreshUnreadBadge() {
        OllieBadge.setUnread(store.unreadCount)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            panelController.toggle(fromMenuBar: true)
        }
    }

    private func showStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open \(AppIdentity.displayName)", action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Add Control seat…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() {
        panelController.expand(fromMenuBar: true)
    }

    @objc private func openSettings() {
        panelController.expand(fromMenuBar: true)
        store.showingSettings = true
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func installOutsideClickMonitor() {
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.store.isExpanded, self.store.settings.collapseOnOutsideClick else { return }
                let point = NSEvent.mouseLocation
                if !self.panelController.panel.frame.contains(point) {
                    self.panelController.collapse(hard: true)
                }
            }
        }
    }
}

enum DockRouting {
    enum Destination { case panel, companion }
    static func destination(panelOpen: Bool) -> Destination { panelOpen ? .companion : .panel }
}
