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

enum SecureResponseFile {
    static func write(_ data: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if result <= 0 { break }
                written += result
            }
        }
    }

    static func purgeStale(in directory: URL, prefixes: [String], olderThan: TimeInterval = 60) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for file in files where prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

enum AppQueryFreshness {
    static func isFresh(_ note: Notification, maxAge: TimeInterval) -> Bool {
        guard let sent = note.userInfo?["sent_at"] as? NSNumber else { return true }
        let age = Date().timeIntervalSince1970 - sent.doubleValue
        return age >= -5 && age <= maxAge
    }
}
