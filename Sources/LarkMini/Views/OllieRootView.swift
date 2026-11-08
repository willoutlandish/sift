import SwiftUI

struct OllieRootView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ZStack(alignment: .top) {
            OllieStyle.bg.ignoresSafeArea()
            switch store.ollieScreen {
            case .today:
                OllieTodayView(
                    onActivity: { shop in store.ollieScreen = .activity(resource: shop.resource, name: shop.name) },
                    onApprovals: { shop in store.ollieScreen = .approvals(resource: shop.resource, name: shop.name) }
                )
            case .activity(let resource, let name):
                OllieActivityView(resource: resource, name: name) { store.ollieScreen = .today }
            case .approvals(let resource, let name):
                OllieApprovalsView(resource: resource, name: name) { store.ollieScreen = .today }
            }
        }
    }
}

enum OllieScreen: Equatable {
    case today
    case activity(resource: String, name: String)
    case approvals(resource: String?, name: String?)
    static var initial: Self {
        switch OllieReadback.screen {
        case "activity": return .activity(resource: OllieReadback.resource, name: "Activity")
        case "waiting": return .approvals(resource: nil, name: nil)
        default: return .today
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
