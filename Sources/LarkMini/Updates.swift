import AppKit
import Sparkle
import SwiftUI
import Combine

// Sparkle owns validation, download, version comparison and installation.
// Only the quiet-moment policy and critical native-panel gate live here.
struct QuietUpdatePolicy {
    var lastActivity: Date
    var panelOpen = false
    var windowFocused = false
    var confirmationOpen = false
    var decisionInFlight = false

    mutating func mayInstall(now: Date) -> Bool {
        if panelOpen || windowFocused || confirmationOpen || decisionInFlight {
            lastActivity = now
            return false
        }
        return now.timeIntervalSince(lastActivity) >= 180
    }
}

enum RequiredUpdateGate {
    struct Release { let version: String; let critical: Bool }
    static func requiredVersion(current: String, releases: [Release]) -> String? {
        let comparator = SUStandardVersionComparator.default
        guard releases.contains(where: { $0.critical && comparator.compareVersion(current, toVersion: $0.version) == .orderedAscending }),
              let newest = releases.max(by: { comparator.compareVersion($0.version, toVersion: $1.version) == .orderedAscending }),
              comparator.compareVersion(current, toVersion: newest.version) == .orderedAscending else { return nil }
        return newest.version
    }
}

@MainActor
final class OllieUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = OllieUpdates()
    @Published private(set) var requiredVersion: String?
    @Published private(set) var blockedReason: String?
    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    private let requiredKey = "OllieRequiredUpdateVersion"

    var panelOpen: () -> Bool = { true }
    var beforeInstall: () -> Void = {}
    private var quiet = QuietUpdatePolicy(lastActivity: Date())
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var confirmations = Set<UUID>()
    private var decisions = 0
    var companionBusy = false {
        didSet { if companionBusy || companionBusy != oldValue { activity() } }
    }

    func activity() { quiet.lastActivity = Date() }
    func confirmation(_ id: UUID, open: Bool) {
        if open { confirmations.insert(id) } else { confirmations.remove(id) }
        activity()
    }
    func beginDecision() { decisions += 1; activity() }
    func endDecision() { decisions = max(0, decisions - 1); activity() }

    private var blocked: Bool {
        companionBusy || !confirmations.isEmpty || decisions > 0 || NSApp.modalWindow != nil ||
            NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private func installWhenQuiet() {
        quiet.panelOpen = panelOpen()
        quiet.windowFocused = NSApp.windows.contains { $0.isKeyWindow || ($0.isMainWindow && NSApp.isActive) }
        quiet.confirmationOpen = blocked
        quiet.decisionInFlight = decisions > 0
        guard quiet.mayInstall(now: Date()), let install = installNow else { return }
        installNow = nil
        beforeInstall()
        install()
    }

    func start() {
        // A dev identity must never install a production bundle into itself.
        guard !AppIdentity.isDevelopment else {
            if OllieReadback.screen == "update-required" { requiredVersion = "0.1.1" }
            return
        }
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activity() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installWhenQuiet() }
        }
        if let saved = UserDefaults.standard.string(forKey: requiredKey),
           SUStandardVersionComparator.default.compareVersion(current, toVersion: saved) == .orderedAscending {
            requiredVersion = saved
        } else { UserDefaults.standard.removeObject(forKey: requiredKey) }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller?.updater.automaticallyChecksForUpdates = true
        controller?.updater.automaticallyDownloadsUpdates = true
        controller?.updater.updateCheckInterval = 6 * 60 * 60
        controller?.updater.checkForUpdatesInBackground()
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        if let version = RequiredUpdateGate.requiredVersion(current: current,
            releases: appcast.items.map { .init(version: $0.versionString, critical: $0.isCriticalUpdate) }) {
            requiredVersion = version
            UserDefaults.standard.set(version, forKey: requiredKey)
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        installNow = immediateInstallationBlock
        return true
    }

    static func refusal(companionBusy: Bool, decisionInFlight: Bool, confirmationOpen: Bool) -> String? {
        if companionBusy { return "Finish or close what you're editing in Companion first" }
        if decisionInFlight { return "Wait for your decision to finish before updating" }
        if confirmationOpen { return "Finish or close the open confirmation first" }
        return nil
    }

    func updateNow() {
        // The required-update sheet itself is allowed here; decision confirmations
        // and network writes still prevent even an explicit relaunch.
        blockedReason = Self.refusal(companionBusy: companionBusy, decisionInFlight: decisions > 0,
                                     confirmationOpen: !confirmations.isEmpty || NSApp.modalWindow != nil)
        guard blockedReason == nil else { return }
        if let install = installNow {
            installNow = nil
            beforeInstall()
            install()
        }
        else { controller?.checkForUpdates(nil) }
    }
}

struct UpdateRequiredView: View {
    @ObservedObject private var updates = OllieUpdates.shared
    let update: () -> Void
    let companion: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Update required").font(.title2.bold())
            Text("Install the latest Ollie update to continue using this panel.")
                .multilineTextAlignment(.center)
            if let reason = updates.blockedReason {
                Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Update now", action: update).buttonStyle(.borderedProminent)
            Button("Open Companion", action: companion)
        }
        .padding(28).frame(width: 340)
        .interactiveDismissDisabled()
    }
}
