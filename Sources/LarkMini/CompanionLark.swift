import SwiftUI

enum LarkSource: Equatable {
    case direct, companionReadOnly
    static func select(hasCredentials: Bool) -> Self { hasCredentials ? .direct : .companionReadOnly }
    var canWrite: Bool { self == .direct }
}

struct CompanionLarkChat: Identifiable, Equatable {
    let id: String
    let title: String
}

// Mirrors CompanionConversationController and CompanionConversationReadService.
// The server owns authorization (employee identity, existing token, no Act As).
// Its inbox is recent activity; read/unread and pins are explicitly unknown.
enum CompanionLarkRead {
    static func path(query: String) -> String? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return "/api/ops/companion/lark-inbox?days=7&limit=40&page_limit=2" }
        guard (2...120).contains(query.count) else { return nil }
        var components = URLComponents(string: "/api/ops/companion/lark-chats")!
        components.queryItems = [.init(name: "query", value: query), .init(name: "limit", value: "20")]
        return components.string
    }

    static func parse(_ reply: CompanionFetchReply?) -> [CompanionLarkChat]? {
        guard let reply, reply.status == 200,
              let object = try? JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any],
              object["readOnly"] as? Bool == true,
              let source = object["source"] as? [String: Any],
              ["connected", "partial"].contains(source["state"] as? String ?? ""),
              let rows = object["data"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            let conversation = row["conversation"] as? [String: Any]
            let ref = conversation?["ref"] as? [String: Any]
            guard let id = row["id"] as? String ?? ref?["externalId"] as? String,
                  id.range(of: #"^oc_[A-Za-z0-9]+$"#, options: .regularExpression) != nil,
                  let title = row["title"] as? String ?? conversation?["title"] as? String else { return nil }
            return CompanionLarkChat(id: id, title: title)
        }
    }
}

enum CompanionLarkState: Equatable {
    case loading, signedOut, unavailable, ready([CompanionLarkChat])

    static func from(_ reply: CompanionFetchReply?, sessionMissing: Bool = false) -> Self {
        if sessionMissing || reply?.status == 401 || reply?.status == 419 ||
            (reply.flatMap { URL(string: $0.url) }.map(CompanionSignInProbe.isSignIn) ?? false) {
            return .signedOut
        }
        guard let chats = CompanionLarkRead.parse(reply) else { return .unavailable }
        return .ready(chats)
    }
}

struct CompanionLarkView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = CompanionApprovalsMonitor.shared
    @State private var query = ""
    @State private var state = CompanionLarkState.loading
    @State private var inFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lark").font(.title2)
            Text("Recent activity · Read-only").foregroundStyle(.secondary)
            HStack {
                TextField("Find a chat (at least 2 characters)", text: $query).onSubmit { Task { await load() } }
                Button("Search") { Task { await load() } }.disabled(inFlight || (query.count == 1))
            }
            switch state {
            case .loading:
                ProgressView("Loading Lark…").controlSize(.small)
            case .signedOut:
                Text("Sign in to Companion to see Lark here")
                Button("Sign in to Companion") { store.openCompanionSignIn() }
            case .unavailable:
                Text("Lark isn't available for your account")
            case .ready(let chats):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chats) { chat in
                            HStack {
                                Text(chat.title)
                                Spacer()
                                Button("Open in Lark") {
                                    if let url = URL(string: "https://applink.larksuite.com/client/chat/open?chatId=" + chat.id) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        }
                        if chats.isEmpty { Text("No recent chats to show").foregroundStyle(.secondary) }
                    }
                }
            }
            Button("Refresh") { Task { await load() } }.disabled(inFlight)
        }
        .padding(16).task { await load() }
        .onChange(of: monitor.state == .signedOut) { signedOut in
            if signedOut { state = .signedOut }
            else { Task { await load() } }
        }
    }

    @MainActor private func load() async {
        guard !inFlight, let path = CompanionLarkRead.path(query: query) else { return }
        guard monitor.state != .signedOut else { state = .signedOut; return }
        inFlight = true
        state = .loading
        defer { inFlight = false }
        let reply = await monitor.fetch(path: path)
        state = .from(reply, sessionMissing: monitor.state == .signedOut)
    }
}
