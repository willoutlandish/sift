import AppKit

enum LarkLaunch {
    enum Choice: Equatable {
        case app
        case web
    }

    static let bundleIdentifier = "com.larksuite.larkApp"
    static let webURL = URL(string: "https://www.larksuite.com/")!

    static func choice(applicationExists: Bool) -> Choice {
        applicationExists ? .app : .web
    }

    static func open() {
        let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        switch choice(applicationExists: application != nil) {
        case .app:
            guard let application else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
                if error != nil { NSWorkspace.shared.open(webURL) }
            }
        case .web:
            NSWorkspace.shared.open(webURL)
        }
    }
}
