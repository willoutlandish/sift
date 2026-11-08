import Foundation
import Sentry

// Reuses the project's existing Sentry service (web config/sentry.php).
// The native SDK is required to collect macOS crashes. Only crash mechanics and
// app identity are retained; free-form event content never leaves this process.
enum CrashReporting {
    static func start() {
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "OllieSentryDSN") as? String,
              !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.enableSwizzling = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableAutoBreadcrumbTracking = false
            options.enableAutoSessionTracking = false
            options.enableAppHangTracking = false
            // Screenshot/view-hierarchy collection is unavailable in the macOS SDK.
            options.maxBreadcrumbs = 0
            options.tracesSampleRate = 0
            options.beforeBreadcrumb = { _ in nil }
            options.beforeSend = { event in sanitized(event) }
        }
    }

    static func sanitized(_ event: Event) -> Event? {
        guard event.level == .fatal else { return nil }
        let clean = Event(level: .fatal)
        clean.eventId = event.eventId
        clean.timestamp = event.timestamp
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        clean.releaseName = AppIdentity.bundleIdentifier + "@" + version
        clean.tags = ["app_version": version, "app_identity": AppIdentity.bundleIdentifier]
        clean.exceptions = event.exceptions?.map { exception in
            let safe = Exception(value: "Native crash", type: "NativeCrash")
            if let stack = exception.stacktrace {
                let frames = stack.frames.map { original in
                    let frame = Frame()
                    // Addresses are sufficient to locate native frames without filenames,
                    // exception messages, thread names, locals, or request data.
                    frame.instructionAddress = address(original.instructionAddress)
                    frame.imageAddress = address(original.imageAddress)
                    frame.symbolAddress = address(original.symbolAddress)
                    return frame
                }
                safe.stacktrace = SentryStacktrace(frames: frames, registers: [:])
            }
            return safe
        }
        return clean
    }

    private static func address(_ value: String?) -> String? {
        guard let value, value.range(of: #"^0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}
