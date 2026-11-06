import Foundation

enum AppQueryLog {
    private static let lock = NSLock()

    static func record(_ kind: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = stamp + " " + kind + "\n"
        let directory = AppPaths.supportDirectory
        let log = directory.appendingPathComponent("app-queries.log")
        let last = directory.appendingPathComponent("last-app-query")
        try? line.write(to: last, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: last.path)
        if !FileManager.default.fileExists(atPath: log.path) {
            try? line.write(to: log, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        if let data = line.data(using: .utf8) {
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }
}

final class QueryObserverBag {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func observe(_ name: Notification.Name, using block: @escaping (Notification) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: nil, using: block))
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}
