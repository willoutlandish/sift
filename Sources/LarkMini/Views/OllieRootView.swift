import SwiftUI

struct OllieRootView: View {
    @EnvironmentObject var store: Store
    @State private var screen = Screen.today

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
