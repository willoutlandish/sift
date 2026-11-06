import Foundation

enum AppIdentity {
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.outlandish.ollie.dev"
    }

    static var isDevelopment: Bool {
        isDevelopment(bundleIdentifier: bundleIdentifier)
    }

    static var displayName: String {
        isDevelopment ? "Ollie Dev" : "Ollie"
    }

    static var urlScheme: String {
        urlScheme(bundleIdentifier: bundleIdentifier)
    }

    static var supportFolder: String {
        supportFolder(bundleIdentifier: bundleIdentifier)
    }

    static func isDevelopment(bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasSuffix(".dev")
    }

    static func urlScheme(bundleIdentifier: String) -> String {
        isDevelopment(bundleIdentifier: bundleIdentifier) ? "ollie-dev" : "ollie"
    }

    static func supportFolder(bundleIdentifier: String) -> String {
        isDevelopment(bundleIdentifier: bundleIdentifier) ? "Ollie Dev" : "Ollie"
    }

    static func notificationName(_ name: String, bundleIdentifier: String) -> String {
        "\(name).\(bundleIdentifier)"
    }
}

enum AppPaths {
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent(AppIdentity.supportFolder, isDirectory: true)
        try? fm.createDirectory(at: current, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return current
    }()
}
