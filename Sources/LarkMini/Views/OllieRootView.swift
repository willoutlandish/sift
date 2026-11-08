import SwiftUI

struct OllieRootView: View {
    @EnvironmentObject var store: Store
    @State private var screen: Screen

    init() {
        let resource = OllieReadback.resource
        switch OllieReadback.screen {
        case "activity": _screen = State(initialValue: .activity(resource: resource, name: "Activity"))
        case "waiting": _screen = State(initialValue: .approvals(resource: nil, name: nil))
        default: _screen = State(initialValue: .today)
        }
    }

    private enum Screen: Equatable {
        case today
        case activity(resource: String, name: String)
        case approvals(resource: String?, name: String?)
    }

    var body: some View {
        ZStack(alignment: .top) {
            OllieStyle.bg.ignoresSafeArea()
            switch screen {
            case .today:
                OllieTodayView(
                    onActivity: { shop in screen = .activity(resource: shop.resource, name: shop.name) },
                    onApprovals: { shop in screen = .approvals(resource: shop.resource, name: shop.name) }
                )
            case .activity(let resource, let name):
                OllieActivityView(resource: resource, name: name) { screen = .today }
            case .approvals(let resource, let name):
                OllieApprovalsView(resource: resource, name: name) { screen = .today }
            }
        }
    }
}

// Extends the existing development panel-check harness, never normal app routing.
// Configuration is placed only in an ignored dev bundle for input-free screenshots.
enum OllieReadback {
    static var screen: String? {
        guard AppIdentity.isDevelopment, CommandLine.arguments.contains("--show-panel-check") else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "OllieReadbackScreen") as? String
    }
    static var resource: String { Bundle.main.object(forInfoDictionaryKey: "OllieReadbackResource") as? String ?? "" }
}
