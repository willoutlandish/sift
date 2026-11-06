import AppKit
import UserNotifications

/// Device-only preferences keep the shared CLI/state-file contract unchanged.
@MainActor
final class Notifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()
    @Published var enabled = UserDefaults.standard.bool(forKey: "notificationsEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
            if enabled { Task { await refresh(request: true) } }
        }
    }
    @Published var sound = UserDefaults.standard.bool(forKey: "notificationSound") {
        didSet { UserDefaults.standard.set(sound, forKey: "notificationSound") }
    }
    enum Access: Equatable {
        case unknown
        case notDetermined
        case denied
        case authorized
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var state = "Not checked"
    @Published private(set) var hint: String?
    @Published private(set) var testResult: String?
    var onOpen: ((String) -> Void)?
    private var submitted = UserDefaults.standard.stringArray(forKey: "notificationEvents") ?? []

    var needsNotificationPermission: Bool {
        access == .notDetermined || access == .denied
    }

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func refresh(request: Bool = false) async {
        guard let center else {
            state = "Unavailable"
            hint = "Open the Ollie app bundle to use macOS notifications."
            access = .unknown
            return
        }
        center.delegate = self
        var settings = await center.notificationSettings()
        if request, enabled, settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { state = "Unavailable"; hint = error.localizedDescription; return }
            settings = await center.notificationSettings()
        }
        hint = nil
        switch settings.authorizationStatus {
        case .notDetermined:
            access = .notDetermined
            state = "Permission not requested"
        case .denied:
            access = .denied
            state = "Blocked by macOS"
            hint = "Allow Ollie in System Settings → Notifications. The edge dot still works."
        case .authorized, .provisional, .ephemeral:
            access = .authorized
            state = settings.alertSetting == .enabled ? "Allowed by macOS" : "Banners off in macOS"
            if settings.alertSetting != .enabled {
                hint = "Enable Ollie alerts in System Settings → Notifications. The edge dot still works."
            } else if sound, settings.soundSetting != .enabled {
                hint = "Sound is off for Ollie in System Settings → Notifications."
            }
        @unknown default:
            access = .denied
            state = "Unavailable"
            hint = "macOS notification permission could not be determined."
        }
    }

    static func shouldPost(enabled: Bool, focused: Bool, duplicate: Bool) -> Bool {
        enabled && !focused && !duplicate
    }

    func post(title: String, body: String, id: String, destination: String) async {
        guard Self.shouldPost(enabled: enabled, focused: PanelBridge.shared.isFocused,
                              duplicate: submitted.contains(id)) else { return }
        await refresh()
        guard let center, state == "Allowed by macOS" else { return }
        // Permission checks suspend; focus/preferences may have changed meanwhile.
        guard Self.shouldPost(enabled: enabled, focused: PanelBridge.shared.isFocused,
                              duplicate: submitted.contains(id)) else { return }
        submitted.append(id)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        content.userInfo = ["destination": destination]
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            submitted = Array(submitted.suffix(200))
            UserDefaults.standard.set(submitted, forKey: "notificationEvents")
        } catch {
            submitted.removeAll { $0 == id }
            hint = "Notification failed: \(error.localizedDescription)"
        }
    }

    func refreshAuthorization() async {
        guard let center else { access = .unknown; return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: access = .notDetermined
        case .denied: access = .denied
        case .authorized, .provisional, .ephemeral: access = .authorized
        @unknown default: access = .denied
        }
    }

    func requestApprovalAuthorization() async {
        guard let center else { access = .unknown; return }
        center.delegate = self
        await refreshAuthorization()
        guard access == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func postBridge(title: String, body: String) async {
        await postDirect(title: title, body: body, id: "bridge-\(UUID().uuidString)", destination: "")
    }

    func postApproval(title: String, body: String, id: String, path: String) async {
        await postDirect(title: title, body: body, id: "approval-\(id)", destination: "companion:\(path)")
    }

    private func postDirect(title: String, body: String, id: String, destination: String) async {
        guard let center else {
            print("Ollie: notification skipped (notifications unavailable)")
            return
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            print("Ollie: notification skipped (notifications not authorized)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        content.userInfo = ["destination": destination, "direct": true]
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func test() async {
        let id = "test-\(UUID().uuidString)"
        await post(title: "Ollie", body: "A quiet nudge. Click to open Ollie.", id: id, destination: "")
        try? await Task.sleep(nanoseconds: 700_000_000)
        let delivered = await center?.deliveredNotifications() ?? []
        if let notification = delivered.first(where: { $0.request.identifier == id }) {
            testResult = "Test delivered to Notification Center. " + (notification.request.content.sound == nil ? "Silent." : "Sound requested.")
        } else {
            testResult = "macOS has not confirmed test delivery. Check Focus and notification settings."
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let direct = notification.request.content.userInfo["direct"] as? Bool == true
            let allowed = direct ? !PanelBridge.shared.isFocused : (enabled && !PanelBridge.shared.isFocused)
            completionHandler(allowed ? (sound ? [.banner, .sound] : [.banner]) : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let destination = response.notification.request.content.userInfo["destination"] as? String ?? ""
        Task { @MainActor in onOpen?(destination); completionHandler() }
    }
}
