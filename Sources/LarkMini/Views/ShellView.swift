import SwiftUI

/// The expanded panel: a rail that never moves, and one content pane.
struct ShellView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RailView()
            Rectangle().fill(SiftStyle.line).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.pane {
        case .settings:
            SettingsView()
        case .control:
            ControlChatView()
        case .ollie:
            OllieTodoView()
        case .chat:
            if let chat = store.openChat {
                ConversationView(chat: chat)
            } else {
                ChatListView()
            }
        case .lark:
            if store.auth != .signedIn {
                SignInView()
            } else {
                ChatListView()
            }
        }
    }
}
