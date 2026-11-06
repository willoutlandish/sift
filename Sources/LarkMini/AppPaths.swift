import Foundation

enum AppPaths {
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("Ollie", isDirectory: true)
        try? fm.createDirectory(at: current, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return current
    }()
}
