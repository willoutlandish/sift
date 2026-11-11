import AppKit
import CoreServices
import Foundation

/// Small command surface so an agent can configure Ollie without touching the UI.
enum CLI {
    static func run(arguments: [String]) {
        if arguments.first == "companion" {
            exit(companion(Array(arguments.dropFirst())))
        }
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            status = await dispatch(arguments)
            semaphore.signal()
        }
        semaphore.wait()
        exit(status)
    }

    private static func dispatch(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 0
        }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "setup": return try await setup(rest)
            case "bootstrap": return try await bootstrap(rest)
            case "login": return try await login(rest)
            case "logout": return logout()
            case "status": return try await status(rest)
            case "chats": return try await chats(rest)
            case "messages": return try await messagesCommand(rest)
            case "pins": return try await pins(rest)
            case "control": return try await control(rest)
            case "doctor": return try await doctor(rest)
            case "settings": return settingsCommand(rest)
            case "suggest", "suggestions": return suggest(rest)
            case "open": return openApp()
            case "selftest": return selftest()
            case "help", "--help", "-h": print(usage); return 0
            default:
                return fail("Unknown command '\(command)'. Try ollie help.")
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: - Commands

    private static func setup(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        let store = TokenStore()
        guard let appId = flags.value("--app-id"), !appId.isEmpty else {
            return fail("setup needs --app-id. Find both values at open.larksuite.com → your app → Credentials & Basic Info")
        }
        var secret = flags.value("--app-secret")
        if secret == nil, let path = flags.value("--app-secret-file") {
            secret = try? String(contentsOfFile: path, encoding: .utf8)
        }
        if secret == nil || secret == "-" {
            secret = readStdinLine()
        }
        guard let appSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !appSecret.isEmpty else {
            return fail("No app secret given. Use --app-secret-file, --app-secret - (stdin) or --from-lark-cli")
        }
        store.setCredentials(TokenStore.Credentials(appId: appId, appSecret: appSecret))
        return ok(["ok": true, "app_id": appId, "stored": "~/Library/Application Support/Ollie/credentials.json"])
    }

    /// One command for another person's agent: store credentials, start the
    /// device flow, and optionally set the Control seat.
    private static func bootstrap(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        guard let appId = flags.value("--app-id"), !appId.isEmpty else {
            return fail("bootstrap needs --app-id (and the secret on stdin)")
        }
        var secret = flags.value("--app-secret")
        if secret == nil, let path = flags.value("--app-secret-file") {
            secret = try? String(contentsOfFile: path, encoding: .utf8)
        }
        if secret == nil || secret == "-" {
            secret = readStdinLine()
        }
        guard let appSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !appSecret.isEmpty else {
            return fail("No app secret given. Pipe it on stdin: printf '%s' \"$SECRET\" | ollie bootstrap --app-id ...")
        }

        let tokens = TokenStore()
        tokens.setCredentials(TokenStore.Credentials(appId: appId, appSecret: appSecret))

        let api = LarkAPI(tokens: tokens)
        let code = try await api.startDeviceFlow()

        var payload: [String: Any] = [
            "ok": true,
            "app_id": appId,
            "user_code": code.userCode,
            "verification_url": code.verifyURL.absoluteString,
            "device_code": code.deviceCode,
            "expires_in": code.expiresIn,
            "next": "ollie login --device-code \(code.deviceCode)"
        ]

        if let agentId = flags.value("--agent-id") {
            let host = flags.value("--host")
            if let info = await PaseoClient().info(agentId: agentId, host: host) {
                let seat = ControlSeat(agentId: agentId, title: flags.value("--title") ?? info.title, host: host)
                StateFile.shared.update { $0.control = seat }
                payload["control"] = ["agent_id": seat.agentId, "title": seat.title,
                                      "host": host ?? "", "status": info.status]
            } else {
                payload["control_error"] = "No Paseo session found for \(agentId) on \(host ?? "this Mac")"
            }
        }
        return ok(payload)
    }

    private static func login(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        let api = LarkAPI(tokens: TokenStore())
        if let code = flags.value("--device-code") {
            let pending = DeviceCode(
                deviceCode: code,
                userCode: flags.value("--user-code") ?? "",
                verifyURL: URL(string: flags.value("--verify-url") ?? "https://open.larksuite.com")!,
                interval: Int(flags.value("--interval") ?? "5") ?? 5,
                expiresIn: Int(flags.value("--expires") ?? "240") ?? 240
            )
            try await api.pollDeviceFlow(pending)
            return try await printSignedIn(api)
        }

        let code = try await api.startDeviceFlow()
        if flags.has("--no-wait") {
            return ok([
                "ok": true,
                "user_code": code.userCode,
                "verification_url": code.verifyURL.absoluteString,
                "device_code": code.deviceCode,
                "expires_in": code.expiresIn,
                "interval": code.interval,
                "next": "ollie login --device-code \(code.deviceCode)"
            ])
        }
        try await api.pollDeviceFlow(code)
        return try await printSignedIn(api)
    }

    private static func printSignedIn(_ api: LarkAPI) async throws -> Int32 {
        var payload: [String: Any] = ["ok": true, "signed_in": true]
        if let me = try? await api.userInfo() {
            StateFile.shared.update { $0.meOpenId = me.openId }
            await api.setMeId(me.openId)
            payload["user"] = ["name": me.name, "open_id": me.openId]
        }
        return ok(payload)
    }

    private static func logout() -> Int32 {
        TokenStore().setTokens(nil)
        return ok(["ok": true, "signed_out": true])
    }

    private static func status(_ args: [String]) async throws -> Int32 {
        let store = TokenStore()
        var payload: [String: Any] = ["ok": true]
        payload["app_id"] = store.credentials?.appId ?? NSNull()
        guard let tokens = store.tokens else {
            payload["signed_in"] = false
            return ok(payload)
        }
        payload["signed_in"] = true
        payload["expires_at"] = ISO8601DateFormatter().string(from: tokens.expiresAt)
        payload["refresh_expires_at"] = ISO8601DateFormatter().string(from: tokens.refreshExpiresAt)
        let api = LarkAPI(tokens: store)
        if let me = try? await api.userInfo() {
            payload["user"] = ["name": me.name, "open_id": me.openId]
        } else {
            payload["user"] = NSNull()
        }
        return ok(payload)
    }

    private static func chats(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        let limit = Int(flags.value("--limit") ?? "20") ?? 20
        let api = LarkAPI(tokens: TokenStore())
        let listed = try await api.listChats()
        let slice = listed.chats.prefix(limit)
        let rows: [[String: Any]] = slice.map { chat in
            [
                "chat_id": chat.id,
                "name": chat.name,
                "type": chat.isP2P ? "p2p" : (chat.isTopic ? "topic" : "group"),
                "avatar": chat.avatar?.absoluteString ?? NSNull()
            ]
        }
        return ok(["ok": true, "count": listed.chats.count, "chats": rows])
    }

    private static func messagesCommand(_ args: [String]) async throws -> Int32 {
        let flags = Flags(args)
        guard let chatId = flags.value("--chat-id") else {
            return fail("messages needs --chat-id (see ollie chats)")
        }
        let limit = Int(flags.value("--limit") ?? "10") ?? 10
        let page = try await LarkAPI(tokens: TokenStore()).messages(chatId: chatId, pageSize: min(50, max(1, limit)))
        let rows: [[String: Any]] = page.messages.suffix(limit).map { message in
            [
                "id": message.id,
                "type": message.type,
                "text": message.text,
                "ts": message.ts,
                "mine": message.isMine,
                "image_key": message.imageKey ?? NSNull(),
                "file_name": message.fileName ?? NSNull()
            ]
        }
        return ok(["ok": true, "count": rows.count, "has_more": page.next != nil, "messages": rows])
    }

    private static func settingsCommand(_ args: [String]) -> Int32 {
        guard args.first == "set" else { return fail("settings needs set --show-in menubar|edge|both") }
        let flags = Flags(Array(args.dropFirst()))
        guard let raw = flags.value("--show-in") else {
            return fail("settings set needs --show-in menubar|edge|both")
        }
        guard let mode = ShowIn(rawValue: raw) else {
            return fail("--show-in must be menubar, edge or both")
        }
        StateFile.shared.update { $0.settings.showIn = mode }
        postQuery(.appSettingsChanged, userInfo: ["home": AppPaths.supportDirectory.path])
        return ok(["ok": true, "show_in": mode.rawValue])
    }

    private static func pins(_ args: [String]) async throws -> Int32 {
        let store = TokenStore()
        let state = StateFile.shared
        guard let sub = args.first else {
            return ok(["ok": true, "pinned": state.current.pinned])
        }
        switch sub {
        case "list":
            return ok(["ok": true, "pinned": state.current.pinned])
        case "add":
            guard args.count > 1 else { return fail("pins add needs a chat id or --name") }
            var target = args[1]
            if target.hasPrefix("--name") {
                let needle = args.count > 2 ? args[2] : ""
                let api = LarkAPI(tokens: store)
                let listed = try await api.listChats()
                guard let match = listed.chats.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame })
                        ?? listed.chats.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) else {
                    return fail("No chat matching '\(needle)'")
                }
                target = match.id
            }
            var pinned = state.current.pinned
            guard !pinned.contains(target) else {
                return ok(["ok": true, "pinned": pinned, "note": "already pinned"])
            }
            guard pinned.count < 10 else { return fail("Ten pins is the limit") }
            pinned.append(target)
            state.update { $0.pinned = pinned }
            return ok(["ok": true, "pinned": pinned])
        case "remove", "rm":
            guard args.count > 1 else { return fail("pins remove needs a chat id") }
            let pinned = state.current.pinned.filter { $0 != args[1] }
            state.update { $0.pinned = pinned }
            return ok(["ok": true, "pinned": pinned])
        case "clear":
            state.update { $0.pinned = [] }
            return ok(["ok": true, "pinned": []])
        default:
            return fail("Unknown pins command '\(sub)'")
        }
    }

    private static func control(_ args: [String]) async throws -> Int32 {
        let state = StateFile.shared
        guard let sub = args.first else {
            return ok(controlStatus(state))
        }
        switch sub {
        case "status":
            return ok(controlStatus(state))
        case "set", "add":
            let flags = Flags(args)
            guard let agentId = flags.value("--agent-id") ?? (args.count > 1 && !args[1].hasPrefix("--") ? args[1] : nil) else {
                return fail("control set needs --agent-id <paseo session id>")
            }
            let client = PaseoClient()
            guard PaseoClient.isAvailable else { return fail("Paseo is not installed") }
            guard let info = await client.info(agentId: agentId, host: flags.value("--host")) else {
                return fail("No Paseo session found for \(agentId)")
            }
            let seat = ControlSeat(agentId: agentId, title: flags.value("--title") ?? info.title,
                                   host: flags.value("--host"),
                                   provider: flags.value("--provider") ?? AgentProviders.fallback)
            state.update { $0.control = seat }
            return ok(["ok": true, "control": ["agent_id": seat.agentId, "title": seat.title, "status": info.status]])
        case "options", "find":
            let options = await PaseoClient().controlOptions()
            return ok(["ok": true, "options": options.map { ["id": $0.id, "name": $0.name] }])
        case "off", "remove", "disable":
            state.update { $0.control = nil }
            return ok(["ok": true, "control": NSNull()])
        case "send":
            guard let seat = state.current.control else { return fail("No Control seat configured") }
            let text = args.dropFirst().filter { !$0.hasPrefix("--") }.joined(separator: " ")
            guard !text.isEmpty else { return fail("control send needs a message") }
            try await AgentProviders.resolve(seat.provider)
                .send(id: seat.agentId, host: seat.host, text: text)
            return ok(["ok": true, "sent": true])
        case "digest":
            guard let seat = state.current.control else { return fail("No Control seat configured") }
            let reading = try await AgentProviders.resolve(seat.provider).readFollowing(seat, tail: 80, state: state).1
            let last = reading.messages.last { $0.isAssistant }
            return ok(["ok": true,
                       "activity": reading.activity ?? "",
                       "last": last.map { UpdateText.short($0.text) } ?? ""])
        case "logs":
            guard let seat = state.current.control else { return fail("No Control seat configured") }
            let flags = Flags(args)
            let tail = Int(flags.value("--tail") ?? "12") ?? 12
            // Tool calls fill most timeline entries; read a wider bounded window for `tail` messages.
            let messages = try await AgentProviders.resolve(seat.provider)
                .readFollowing(seat, tail: min(200, max(80, tail * 10)), state: state).1.messages
            let rows = messages.suffix(tail).map { ["role": $0.role, "text": $0.text] }
            return ok(["ok": true, "messages": rows])
        case "asks":
            guard let seat = state.current.control else { return fail("No Control seat configured") }
            let reading = try await AgentProviders.resolve(seat.provider).readFollowing(seat, tail: 1, state: state).1
            switch reading.asks {
            case .off: return ok(["ok": true, "configured": false, "asks": []])
            case .unavailable(let reason), .stale(_, let reason): return fail("Asks unavailable: \(reason)")
            case .available(let asks):
                return ok(["ok": true, "configured": true, "asks": asks.map {
                    ["id": $0.id, "plan": $0.plan, "title": $0.title, "question": $0.question,
                     "recommendation": $0.recommendation, "link": $0.link?.absoluteString ?? ""] }])
            }
        default:
            return fail("Unknown control command '\(sub)'")
        }
    }

    private static func controlStatus(_ state: StateFile) -> [String: Any] {
        var payload: [String: Any] = ["ok": true, "paseo": PaseoClient.isAvailable]
        if let seat = state.current.control {
            payload["enabled"] = true
            payload["agent_id"] = seat.agentId
            payload["title"] = seat.title
        } else {
            payload["enabled"] = false
        }
        return payload
    }

    private static func postQuery(_ name: Notification.Name, userInfo: [String: Any]) {
        var info = userInfo
        info["sent_at"] = Date().timeIntervalSince1970
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: info, deliverImmediately: true)
    }

    private static func suggest(_ args: [String]) -> Int32 {
        let sub = args.first ?? "status"
        let off = OllieSuggestionCenter.offKey
        switch sub {
        case "demo":
            let kind = args.dropFirst().first ?? "strategy"
            postQuery(.suggestionRequest, userInfo: ["action": "demo", "kind": kind])
            return ok(["ok": true, "demo": kind, "note": "Shows beside the head once Ollie is collapsed."])
        case "refresh":
            postQuery(.suggestionRequest, userInfo: ["action": "refresh"])
            return ok(["ok": true])
        case "list":
            guard let data = try? Data(contentsOf: OllieSuggestionCenter.snapshotURL),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return fail("Nothing yet. Is Ollie open and signed in to Companion?")
            }
            object["ok"] = true
            return ok(object)
        case "answer":
            // The same as tapping Yes or Not now, for end-to-end tests. Ollie Dev only: the real app
            // never takes a Yes from another process.
            guard AppIdentity.isDevelopment else { return fail("suggest answer works in Ollie Dev only; in Ollie, tap it.") }
            let rest = Array(args.dropFirst())
            guard rest.count == 2, ["yes", "no", "not-now"].contains(rest[1]) else {
                return fail("suggest answer needs <id or prefix> yes|not-now (ids from `ollie suggest list`)")
            }
            postQuery(.suggestionRequest, userInfo: ["action": "answer", "id": rest[0], "yes": rest[1] == "yes"])
            return ok(["ok": true, "note": "Sent; check `ollie suggest list` for the outcome."])
        case "watch", "unwatch":
            guard let resource = args.dropFirst().first, !resource.isEmpty else { return fail("suggest \(sub) needs a shop resource id") }
            var list = UserDefaults.standard.stringArray(forKey: OllieSuggestionCenter.watchKey) ?? []
            list.removeAll { $0 == resource }
            if sub == "watch" { list.append(resource) }
            UserDefaults.standard.set(list, forKey: OllieSuggestionCenter.watchKey)
            postQuery(.suggestionRequest, userInfo: ["action": "refresh"])
            return ok(["ok": true, "watched": list])
        case "on", "off":
            UserDefaults.standard.set(sub == "off", forKey: off)
            postQuery(.suggestionRequest, userInfo: ["action": "settings"])
            return ok(["ok": true, "enabled": sub == "on"])
        case "status":
            return ok(["ok": true, "enabled": !UserDefaults.standard.bool(forKey: off)])
        default:
            return fail("Unknown suggest command '\(sub)'. Use demo, refresh, on, off or status.")
        }
    }

    private static func companion(_ args: [String]) -> Int32 {
        let state = StateFile.shared
        guard let sub = args.first else {
            return companionStatus(state)
        }
        switch sub {
        case "status":
            return companionStatus(state)
        case "pace":
            return companionPace(state)
        case "drag-map":
            return companionDragMap(state)
        case "set":
            let flags = Flags(args)
            guard let raw = flags.value("--url") else {
                return fail("companion set needs --url <http(s)://host[:port]>")
            }
            guard let url = CompanionConfig.validatedURL(raw) else {
                return fail("Companion URL must be an absolute http or https URL")
            }
            state.update { $0.companionURL = url.absoluteString }
            return ok(["ok": true, "url": url.absoluteString])
        case "open":
            guard let base = CompanionConfig.validatedURL(state.current.effectiveCompanionURL) else {
                return fail("No Companion URL configured. Run ollie companion set --url http://host:port")
            }
            let path = Flags(args).value("--path") ?? ""
            guard let target = CompanionConfig.cliTargetURL(base: base, path: path) else {
                return fail("--path must stay on the configured Companion origin")
            }
            if companionOpenRequest(base: base, path: path) {
                return ok(["ok": true, "url": target.absoluteString, "path": path])
            }
            let normalized = path.isEmpty ? "" : (path.hasPrefix("/") ? path : "/" + path)
            let accepted = CompanionPath.accepted(path.isEmpty ? nil : path)
            guard path.isEmpty || accepted == normalized else {
                return fail("Ollie is not running; open Ollie once, then retry this path.")
            }
            guard let openURL = companionOpenURL(path: accepted) else {
                return fail("Could not build the Companion window URL")
            }
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
            guard NSWorkspace.shared.open(openURL) else {
                return fail("Could not open the Companion window")
            }
            return ok(["ok": true, "url": target.absoluteString, "path": accepted, "fallback": true])
        default:
            return fail("Unknown companion command '\(sub)'")
        }
    }

    private struct CompanionSessionReply {
        var signedIn = false
        var cookiePresent = false
    }

    private static func companionStatus(_ state: StateFile) -> Int32 {
        var payload: [String: Any] = ["ok": true]
        let raw = state.current.effectiveCompanionURL
        payload["url"] = raw
        guard let base = CompanionConfig.validatedURL(raw) else {
            payload["valid"] = false
            payload["signed_in"] = NSNull()
            payload["cookie_present"] = NSNull()
            payload["session_cookie_state"] = "unknown"
            return ok(payload)
        }
        if let reply = companionSessionStatus(for: base) {
            payload["signed_in"] = reply.signedIn
            payload["cookie_present"] = reply.cookiePresent
            payload["session_cookie_state"] = "checked"
        } else {
            payload["signed_in"] = NSNull()
            payload["cookie_present"] = NSNull()
            payload["session_cookie_state"] = "unknown"
        }
        return ok(payload)
    }

    /// The CLI cannot read the app's live WebKit cookie store, so ask a running
    /// Ollie with the same support directory. nil means no app answered.
    private static func companionSessionStatus(for base: URL) -> CompanionSessionReply? {
        let request = UUID().uuidString
        let prefix = "companion-status-\(request)-"
        let directory = AppPaths.supportDirectory
        let fileManager = FileManager.default
        postQuery(.companionStatusRequest, userInfo: [
            "id": request, "url": base.absoluteString, "home": directory.path
        ])
        let deadline = Date().addingTimeInterval(CompanionProbeCoordinator.probeTimeout + 2)
        var sawResponse = false
        var firstResponseAt: Date?
        var reply = CompanionSessionReply()
        while Date() < deadline {
            if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix(prefix) {
                    if firstResponseAt == nil { firstResponseAt = Date() }
                    sawResponse = true
                    if let data = try? Data(contentsOf: file),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        reply.signedIn = reply.signedIn || (object["signed_in"] as? Bool ?? false)
                        reply.cookiePresent = reply.cookiePresent || (object["cookie_present"] as? Bool ?? false)
                    }
                    try? fileManager.removeItem(at: file)
                }
            }
            if reply.signedIn { break }
            if sawResponse, let firstResponseAt, Date().timeIntervalSince(firstResponseAt) > 0.3 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? fileManager.removeItem(at: file)
            }
        }
        return sawResponse ? reply : nil
    }

    private static func companionPace(_ state: StateFile) -> Int32 {
        guard let base = CompanionConfig.validatedURL(state.current.effectiveCompanionURL) else {
            return fail("No Companion URL configured. Run ollie companion set --url http://host:port")
        }
        let request = UUID().uuidString
        let prefix = "companion-pace-\(request)-"
        let directory = AppPaths.supportDirectory
        let fileManager = FileManager.default
        postQuery(.companionPaceRequest,
                  userInfo: ["id": request, "url": base.absoluteString, "home": directory.path])
        let deadline = Date().addingTimeInterval(CompanionProbeCoordinator.probeTimeout + 8)
        while Date() < deadline {
            if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix(prefix) {
                    defer { try? fileManager.removeItem(at: file) }
                    if let data = try? Data(contentsOf: file),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        var payload = object
                        payload["ok"] = true
                        return ok(payload)
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        cleanupCompanionFiles(prefix: prefix, in: directory)
        return fail("No running Ollie answered the pace request.")
    }

    private static func companionDragMap(_ state: StateFile) -> Int32 {
        guard let base = CompanionConfig.validatedURL(state.current.effectiveCompanionURL) else {
            return fail("No Companion URL configured. Run ollie companion set --url http://host:port")
        }
        let request = UUID().uuidString
        let prefix = "companion-drag-map-\(request)-"
        let directory = AppPaths.supportDirectory
        let fileManager = FileManager.default
        postQuery(.companionDragMapRequest,
                  userInfo: ["id": request, "url": base.absoluteString, "home": directory.path])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let files = try? fileManager.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix(prefix) {
                    defer { try? fileManager.removeItem(at: file) }
                    if let data = try? Data(contentsOf: file),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        var payload = object
                        payload["ok"] = true
                        return ok(payload)
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        cleanupCompanionFiles(prefix: prefix, in: directory)
        return fail("No running Ollie answered the drag-map request.")
    }

    private static func companionOpenRequest(base: URL, path: String) -> Bool {
        let request = UUID().uuidString
        let prefix = "companion-open-\(request)-"
        let directory = AppPaths.supportDirectory
        let fileManager = FileManager.default
        postQuery(.companionOpenRequest, userInfo: [
            "id": request, "url": base.absoluteString, "path": path, "home": directory.path
        ])
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix(prefix) {
                    let opened = (try? Data(contentsOf: file))
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        .flatMap { $0["opened"] as? Bool } ?? false
                    try? fileManager.removeItem(at: file)
                    if opened {
                        cleanupCompanionFiles(prefix: prefix, in: directory)
                        return true
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        cleanupCompanionFiles(prefix: prefix, in: directory)
        return false
    }

    private static func cleanupCompanionFiles(prefix: String, in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func companionOpenURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = AppIdentity.urlScheme
        components.host = "companion"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    private static func doctor(_ args: [String]) async throws -> Int32 {
        let store = TokenStore()
        var checks: [[String: Any]] = []
        let creds = store.credentials
        checks.append(["check": "app credentials", "ok": creds != nil,
                       "detail": creds.map { "app id \($0.appId)" } ?? "run ollie setup"])
        let tokenOK = (try? await LarkAPI(tokens: store).accessToken()) != nil
        checks.append(["check": "user token", "ok": tokenOK,
                       "detail": tokenOK ? "valid or refreshed" : "run ollie login"])
        if tokenOK {
            do {
                let api = LarkAPI(tokens: store)
                let listed = try await api.listChats()
                let p2p = listed.chats.filter(\.isP2P).count
                checks.append(["check": "chat list", "ok": true,
                               "detail": "\(listed.chats.count) chats, \(p2p) direct"])
            } catch {
                checks.append(["check": "chat list", "ok": false, "detail": error.localizedDescription])
            }
        }
        let allOK = checks.allSatisfy { $0["ok"] as? Bool == true }
        if allOK { return ok(["ok": true, "checks": checks]) }
        printJSON(["ok": false, "checks": checks])
        return 1
    }

    private static func selftest() -> Int32 {
        let visible = NSRect(x: 0, y: 0, width: 1600, height: 900)
        let size = NSSize(width: 340, height: 560)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            checks.append(["check": name, "ok": passed])
        }
        check("handle docked to right edge",
              PanelGeometry.rightEdge(size: NSSize(width: 72, height: 72), in: visible, margin: 10)
                == NSRect(x: 1518, y: 414, width: 72, height: 72))
        check("panel docked to right edge",
              PanelGeometry.rightEdge(size: size, in: visible, margin: 12)
                == NSRect(x: 1248, y: 170, width: 340, height: 560))
        check("partial name matches", SearchMatch.matches(name: "Morgan Ellis", query: "mor"))
        check("reordered words match", SearchMatch.matches(name: "Morgan Ellis", query: "ell mor"))
        check("punctuation-separated match", SearchMatch.matches(name: "Morgan Ellis", query: "mor-ell"))
        check("unrelated query rejected", !SearchMatch.matches(name: "Design Room", query: "finance"))
        let unseen = Preview(text: "x", ts: 0, messageId: "m2", fromMe: false)
        check("unknown baseline is not unread",
              !UnreadPolicy.isUnread(preview: unseen, lastSeenMessageId: nil, muted: false))
        check("new activity is unread",
              UnreadPolicy.isUnread(preview: unseen, lastSeenMessageId: "m1", muted: false))
        check("seen activity is read",
              !UnreadPolicy.isUnread(preview: unseen, lastSeenMessageId: "m2", muted: false))
        check("own message is read",
              !UnreadPolicy.isUnread(preview: Preview(text: "x", ts: 0, messageId: "m9", fromMe: true),
                                     lastSeenMessageId: "m1", muted: false))

        let allOK = checks.allSatisfy { $0["ok"] as? Bool == true }
        if allOK { return ok(["ok": true, "checks": checks]) }
        printJSON(["ok": false, "checks": checks])
        return 1
    }

    private static func openApp() -> Int32 {
        let bundle = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, error in
            if let error { FileHandle.standardError.write(Data("open failed: \(error.localizedDescription)\n".utf8)) }
            semaphore.signal()
        }
        semaphore.wait()
        return ok(["ok": true, "opened": bundle.path])
    }

    // MARK: - Output

    private static func ok(_ payload: [String: Any]) -> Int32 {
        printJSON(payload)
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        printJSON(["ok": false, "error": message])
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    private static func printJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }

    private static func readStdinLine() -> String? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let usage = """
    ollie — configure and inspect Ollie from the terminal

    USAGE
      ollie <command> [flags]

    COMMANDS
      bootstrap Credentials + sign-in code + optional Control seat in one call
                  printf '%s' "$SECRET" | ollie bootstrap --app-id ID
                    [--agent-id ID --host tcp://host:6767]
      setup     Store the Lark app id and secret
                  --app-id ID --app-secret-file PATH   read secret from a file
                  --app-id ID --app-secret -           read secret from stdin
      login     Sign in with the device flow
                  --no-wait                            print the code and exit
                  --device-code CODE                   finish a previous --no-wait
      status    JSON: signed in, app id, token expiry, user
      chats     JSON: your chats (--limit N, default 20)
      messages  JSON: history for a chat (--chat-id oc_xxx --limit N)
      pins      list | add <chat_id> | add --name "Design" | remove <chat_id> | clear
      control   Optional Paseo seat pinned above your chats
                  set --agent-id ID [--host H] [--provider paseo] [--title T]
                  status | send "text" | logs [--tail N] | digest | asks | off
      companion Open the real Companion web app in its own Ollie window
                  set --url http://host:port
                  status | pace | open [--path /same-origin/path]
                  drag-map                         titlebar geometry and hit map
      suggest   Agent proposals said from Ollie's head ("Yes, do it" / "Not now")
                  demo [strategy|samples|creator]  preview one; nothing is read or written
                  refresh                          read the agents' proposals now
                  list                             what is on offer and what each shop read found
                  answer <id> yes|not-now          as if tapped (Ollie Dev only, for tests)
                  watch | unwatch <resource>       always read this shop's Strategy Manager
                  on | off | status
      settings  set --show-in menubar|edge|both
      doctor    Check credentials, token and chat access
      open      Open the Ollie app
      logout    Forget the current session

    All commands print JSON on stdout and exit 1 on failure.
    """
}

private struct Flags {
    let args: [String]
    init(_ args: [String]) { self.args = args }

    func value(_ name: String) -> String? {
        guard let index = args.firstIndex(of: name), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    func has(_ name: String) -> Bool { args.contains(name) }
}
