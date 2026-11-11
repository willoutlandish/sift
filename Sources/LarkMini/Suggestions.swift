import Foundation

/// Something an agent offers to do, said from Ollie's head: "I think you should… want me to?"
/// Warnings stay in banners and the panel; a suggestion is a proposal with a yes.
struct OllieSuggestion: Equatable, Identifiable {
    enum Action: Equatable {
        /// A same-origin Companion POST the source's own card makes.
        case post(path: String, body: [String: String])
        /// Apply the month's proposed strategy, re-reading it first so a stale draft is never sent.
        case applyDraft(resource: String, applyText: String)
        /// Approve one item from Waiting on you.
        case approve(CompanionTodoItem)
        /// Local preview only: nothing is read or written.
        case demo(String)
    }

    let id: String
    let agent: String
    let shop: String
    let text: String
    var detail: String? = nil
    var yesLabel = "Yes, do it"
    let yes: Action
    /// How the source records "not now"; nil sets it aside on this Mac only.
    var notNow: Action? = nil
    var openPath: String? = nil
    var doneText = "Done"
    var notNowLabel = "Not now"
    var notNowDoneText = "Not now"

    var byline: String { shop.isEmpty ? agent : agent + " · " + shop }
}

enum OllieSuggestions {
    static let strategyRole = "strategy-manager"

    // MARK: Strategy Manager (GET /api/oo/shops/{resource}/strategy-manager)

    private struct StrategyState: Decodable {
        struct Agent: Decodable { let name: String? }
        struct Draft: Decodable { let display: String?; let apply_text: String? }
        struct Check: Decodable { let recommendations: [Recommendation]? }
        struct Recommendation: Decodable {
            let key: String?
            let title: String?
            let reason: String?
            let to_name: String?
            let via: String?
            let dismissed: Bool?
            let handed: Handed?
        }
        /// Any non-null hand-off means it is already with someone.
        struct Handed: Decodable {}
        let agent: Agent?
        let period: String?
        let draft: Draft?
        let check: Check?
    }

    /// The current draft's apply text, or nil when there is no draft now (as the card's refetch reads it).
    static func currentDraftText(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let state = try? JSONDecoder().decode(StrategyState.self, from: data) else { return nil }
        return nonEmpty(state.draft?.apply_text)
    }

    static func strategyPath(resource: String, _ tail: String = "") -> String {
        "/api/oo/shops/" + pathSegment(resource) + "/strategy-manager" + tail
    }

    /// The month's proposed strategy and today's open recommendations, mirroring the
    /// Management chat card (StrategyManagerOllieCard): Apply / Not now with the same routes.
    static func strategyManager(_ body: String, resource: String, shop: String) -> [OllieSuggestion] {
        guard let data = body.data(using: .utf8),
              let state = try? JSONDecoder().decode(StrategyState.self, from: data),
              // The free daily check's own ideas count even before the paid agent is set up.
              state.agent != nil || state.draft != nil || state.check != nil else { return [] }
        let agent = "Strategy Manager"
        var out: [OllieSuggestion] = []
        if let draft = state.draft, let apply = nonEmpty(draft.apply_text), let display = nonEmpty(draft.display),
           let period = nonEmpty(state.period) {
            out.append(OllieSuggestion(
                id: "sm:\(resource):draft:\(period):\(apply)", agent: agent, shop: shop,
                text: display, detail: "Want me to set it as this month's strategy?",
                yesLabel: "Apply", yes: .applyDraft(resource: resource, applyText: apply),
                notNow: .post(path: strategyPath(resource: resource, "/recommendations/" + pathSegment("statement_draft:" + period) + "/dismiss"), body: [:]),
                openPath: "/companion/app", doneText: "Set as this month's strategy"))
        }
        for rec in state.check?.recommendations ?? [] {
            guard let key = nonEmpty(rec.key), let title = nonEmpty(rec.title), rec.dismissed != true else { continue }
            // A role name ("account manager") reads with "the"; a person's name does not.
            let named = nonEmpty(rec.to_name) ?? "team"
            let to = named.first?.isLowercase == true ? "the " + named : named
            // Already with someone (a person's Yes, or later the agent's own record of it): not a new idea.
            // No "handed off without your OK" alarm: the reader keeps only the newest row per key, so an
            // approved hand-off the agent re-records would look unapproved, and its Stop would undo your Yes.
            guard rec.handed == nil else { continue }
            // Nothing here does the work itself: Yes asks the account manager, or hands it to an agent.
            let task = lowerFirst(shortProductNames(title))
            let asks = rec.via == "ask"
            let live = state.agent != nil
            out.append(OllieSuggestion(
                id: "sm:\(resource):rec:\(key)", agent: agent, shop: shop,
                text: asks ? "Want me to ask \(to) to \(task)?" : "Want me to hand this to \(to): \(task)?",
                detail: nonEmpty(rec.reason).map(shortProductNames),
                yesLabel: asks ? "Yes, ask them" : "Yes, send it",
                yes: .post(path: strategyPath(resource: resource, "/recommendations/" + pathSegment(key) + "/apply"), body: [:]),
                notNow: .post(path: strategyPath(resource: resource, "/recommendations/" + pathSegment(key) + "/dismiss"), body: [:]),
                openPath: "/companion/app",
                doneText: live ? (asks ? "Asked \(to)" : "Handed to \(to)")
                    : "Saved for \(to). It's sent once the Strategy Manager is switched on."))
        }
        return out
    }

    // MARK: Any agent's recommended approval (Creator Manager, Ads Manager, …)

    /// Items an agent recommends approving and that you can approve in one tap. Sends to
    /// people outside are left to the panel, where the full message and recipient show.
    /// Sources whose approve sends to someone outside (ControlRoomAnswerService::apply).
    static let outsideSendSources: Set<String> = ["send_approval", "creator_dm_reply", "incentive"]

    static func approvals(_ snapshot: CompanionTodoSnapshot) -> [OllieSuggestion] {
        snapshot.orderedItems.compactMap { item in
            guard item.mine, item.recommendationAnswer == "approve", item.canApprove,
                  item.recipients.isEmpty, item.payloadPreview == nil,
                  !outsideSendSources.contains(item.source) else { return nil }
            return OllieSuggestion(
                id: "approval:\(item.id):\(item.decision?.version ?? "")", agent: item.label, shop: item.shopName,
                text: item.title, detail: nonEmpty(item.recommendation) ?? item.reason,
                yes: .approve(item), openPath: item.itemLink ?? item.reviewPath, doneText: "Approved")
        }
    }

    // MARK: Previews (`ollie suggest demo`)

    static func demo(_ kind: String) -> OllieSuggestion {
        switch kind {
        case "creator", "creators", "creator-manager":
            return OllieSuggestion(
                id: "demo:creator:\(UUID().uuidString)", agent: "Creator Manager", shop: "YUNJAC",
                text: "12 creators asked for samples overnight and all fit the brief. Want me to approve them?",
                detail: "Each one is above 5k followers with a beauty audience; 3 have posted for you before.",
                yes: .demo("creator"), doneText: "Approved 12 samples (preview, nothing sent)")
        case "samples":
            return OllieSuggestion(
                id: "demo:samples:\(UUID().uuidString)", agent: "Strategy Manager", shop: "YUNJAC",
                text: "Want me to hand this to Creator Manager: raise the outreach daily limit from 20 to 30?",
                detail: "8 of 28 samples sent this week, 16 expected by now, with 3 days left.",
                yesLabel: "Yes, send it", yes: .demo("samples"), doneText: "Handed to Creator Manager (preview, nothing sent)")
        default:
            return OllieSuggestion(
                id: "demo:strategy:\(UUID().uuidString)", agent: "Strategy Manager", shop: "YUNJAC",
                text: "Want me to ask Sian to lower the November GMV target to $25,000?",
                detail: "$6,273 in 7 days is 61% of pace; at this rate the month ends near $26,900 against $40,000.",
                yesLabel: "Yes, ask them", yes: .demo("strategy"),
                doneText: "Asked Sian (preview, nothing sent)")
        }
    }

    // MARK: Helpers

    static func pathSegment(_ raw: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!*'()")
        return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
    }

    /// Shop listing titles run to a paragraph ("Primer (1.35 fl oz) – Silicone-Free Grip …");
    /// keep the name, drop the size and the sales copy after a dash.
    static func shortProductNames(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: #"\s*(\([^)]*\))?\s+[–—|]\s+[^.?]*?(?=\s+or\s|\s+is\s|\s+and\s|[.?]|$)"#,
            with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep acronyms and names ("GMV", "YUNJAC") as they are.
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One suggestion at a time, each offered once. "Not now" and answered ids are remembered,
/// bounded to what is still on offer so the list never grows without end.
struct OllieSuggestionQueue {
    private(set) var pending: [OllieSuggestion] = []
    private(set) var handled: Set<String>

    init(handled: Set<String> = []) { self.handled = handled }

    /// Replace the offer with what the sources say now, keeping the existing order.
    mutating func offer(_ current: [OllieSuggestion], source: String) {
        let fresh = current.filter { !handled.contains($0.id) }
        let kept = pending.filter { !$0.id.hasPrefix(source) || fresh.contains($0) }
        pending = kept + fresh.filter { item in !kept.contains { $0.id == item.id } }
    }

    mutating func next() -> OllieSuggestion? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Back to the front, for a suggestion a Lark arrival interrupted.
    mutating func requeue(_ suggestion: OllieSuggestion) {
        guard !handled.contains(suggestion.id), !pending.contains(suggestion) else { return }
        pending.insert(suggestion, at: 0)
    }

    mutating func markHandled(_ id: String) {
        handled.insert(id)
        pending.removeAll { $0.id == id }
    }

    /// A source that is gone (a shop whose Strategy Manager went off) leaves the line too.
    mutating func drop(source: String) {
        pending.removeAll { $0.id.hasPrefix(source) }
    }
}

/// Gathers suggestions after each Companion poll and offers them, one at a time, from the head.
/// Every write goes through the same Companion route the in-app card uses, as the signed-in person.
@MainActor
final class OllieSuggestionCenter: ObservableObject {
    /// One answered suggestion, kept for this session so the Management chat reads as a conversation.
    struct Answered: Identifiable, Equatable {
        let suggestion: OllieSuggestion
        let yes: Bool
        let outcome: String
        let at: Date
        var id: String { suggestion.id }
    }

    static let shared = OllieSuggestionCenter()
    static let strategyInterval: TimeInterval = 600
    /// Shops read per 10-minute round; a bigger roster is read in turn, never starved.
    nonisolated static let maxStrategyShops = 10
    private static let handledKey = "ollieSuggestionsHandled"
    nonisolated static let offKey = "OllieSuggestionsOff"
    /// Shops read every round whatever the roster says (`ollie suggest watch <resource>`).
    nonisolated static let watchKey = "OllieSuggestionsWatch"
    nonisolated static var watched: [String] { UserDefaults.standard.stringArray(forKey: watchKey) ?? [] }
    /// What the last read of each shop found, for `ollie suggest list`.
    private var strategyReads: [String: [String: Any]] = [:]

    weak var store: Store?
    private var queue: OllieSuggestionQueue
    /// Shown and left to fade this session: not offered again until Ollie restarts.
    private var shown = Set<String>()
    private var strategyFetchedAt: Date?
    private var strategyBusy = false
    private var strategyCursor = 0
    /// Bumped by reset(), so a read still in flight from the last session lands nowhere.
    private var generation = 0
    /// Most recent last, so the 500 kept are the newest answers.
    private var handledOrder: [String]
    /// The latest read from each source; the Management chat shows what is still open.
    private var latest: [(source: String, items: [OllieSuggestion])] = []
    @Published private(set) var feed: [OllieSuggestion] = []
    @Published private(set) var history: [Answered] = []
    @Published private(set) var working: Set<String> = []
    @Published private(set) var failures: [String: String] = [:]

    var enabled: Bool { !UserDefaults.standard.bool(forKey: Self.offKey) }
    var pending: [OllieSuggestion] { queue.pending }

    init() {
        handledOrder = UserDefaults.standard.stringArray(forKey: Self.handledKey) ?? []
        queue = OllieSuggestionQueue(handled: Set(handledOrder))
    }

    /// A different Companion, or a signed-out session: nothing from before may be offered or answered.
    func reset() {
        latest = []
        shown = []
        history = []
        failures = [:]
        strategyFetchedAt = nil
        strategyCursor = 0
        generation += 1
        strategyBusy = false
        queue = OllieSuggestionQueue(handled: Set(handledOrder))
        rebuildFeed()
        if store?.bubble?.suggestion != nil { store?.dismissBubble() }
    }

    func monitorDidPoll(snapshot: CompanionTodoSnapshot, shops: [CompanionShopPace]) async {
        offer(OllieSuggestions.approvals(snapshot), source: "approval:")
        // Ideas already in hand go out now; the shop reads below can take a while.
        showNextIfIdle()
        if !strategyBusy, strategyFetchedAt.map({ Date().timeIntervalSince($0) >= Self.strategyInterval }) ?? true {
            await refreshStrategy(shops)
        }
        showNextIfIdle()
    }

    /// Shops with a Strategy Manager on; a small portfolio with no roster flags is read whole,
    /// since the endpoint itself says when the role is off.
    nonisolated static func strategyShops(_ shops: [CompanionShopPace], watched: [String] = []) -> [CompanionShopPace] {
        let flagged = shops.filter { shop in
            watched.contains(shop.resource) || shop.agents.contains { $0.role == OllieSuggestions.strategyRole && $0.on }
        }
        let pool = flagged.isEmpty && shops.count <= 12 ? shops : flagged
        return pool.sorted { $0.name < $1.name }
    }

    /// This round's slice of the pool, starting at `cursor` and wrapping.
    nonisolated static func strategyBatch(_ pool: [CompanionShopPace], cursor: Int) -> [CompanionShopPace] {
        guard !pool.isEmpty else { return [] }
        let count = min(maxStrategyShops, pool.count)
        return (0..<count).map { pool[(cursor + $0) % pool.count] }
    }

    func refreshStrategy(_ shops: [CompanionShopPace]) async {
        let session = generation
        strategyBusy = true
        defer { if session == generation { strategyBusy = false; strategyFetchedAt = Date(); writeSnapshot() } }
        let pool = Self.strategyShops(shops, watched: Self.watched)
        // A shop whose Strategy Manager went off takes its old ideas with it.
        let live = Set(pool.map { "sm:\($0.resource):" })
        for gone in latest.map(\.source) where gone.hasPrefix("sm:") && !live.contains(gone) {
            queue.drop(source: gone)
        }
        let before = latest.count
        latest.removeAll { $0.source.hasPrefix("sm:") && !live.contains($0.source) }
        if latest.count != before { rebuildFeed() }
        let batch = Self.strategyBatch(pool, cursor: strategyCursor)
        strategyCursor = pool.isEmpty ? 0 : (strategyCursor + batch.count) % pool.count
        for shop in batch {
            guard let reply = await CompanionApprovalsMonitor.shared.fetch(path: OllieSuggestions.strategyPath(resource: shop.resource)),
                  session == generation else { return }
            let found = reply.status == 200 ? OllieSuggestions.strategyManager(reply.body, resource: shop.resource, shop: shop.name) : []
            strategyReads[shop.resource] = ["shop": shop.name, "status": reply.status, "ideas": found.count,
                                            "at": ISO8601DateFormatter().string(from: Date())]
            guard reply.status == 200 else { continue }
            offer(found, source: "sm:\(shop.resource):")
        }
    }

    func forceRefresh() {
        strategyFetchedAt = nil
        CompanionApprovalsMonitor.shared.refresh()
    }

    func showDemo(_ kind: String) {
        let demo = OllieSuggestions.demo(kind)
        setLatest([demo] + (latest.first { $0.source == "demo:" }?.items ?? []), source: "demo:")
        store?.offerSuggestion(demo, force: true)
    }

    /// The preview build (`--demo`) starts with one of each in the Management chat.
    func seedDemo() {
        setLatest([OllieSuggestions.demo("strategy"), OllieSuggestions.demo("samples"), OllieSuggestions.demo("creator")], source: "demo:")
    }

    /// Yes or Not now from the Management chat; a bubble about the same thing goes away.
    func answerFromFeed(_ suggestion: OllieSuggestion, yes: Bool) {
        guard !working.contains(suggestion.id) else { return }
        if store?.bubble?.suggestion?.id == suggestion.id { store?.dismissBubble() }
        Task {
            if yes { _ = await self.yes(suggestion) } else { await notNow(suggestion) }
        }
    }

    func showNextIfIdle() {
        guard enabled, let store, store.canOfferSuggestion, let next = queue.next() else { return }
        shown.insert(next.id)
        store.offerSuggestion(next)
    }

    func requeue(_ suggestion: OllieSuggestion) {
        shown.remove(suggestion.id)
        queue.requeue(suggestion)
    }

    /// Remembered only once the source agrees, so a failed dismiss never hides an open idea.
    @discardableResult
    func notNow(_ suggestion: OllieSuggestion) async -> (ok: Bool, message: String) {
        if let action = suggestion.notNow {
            working.insert(suggestion.id)
            let result = await perform(action)
            working.remove(suggestion.id)
            guard result.ok else {
                let message = result.message ?? "Couldn't set that aside."
                failures[suggestion.id] = message
                return (false, message)
            }
        }
        failures[suggestion.id] = nil
        markHandled(suggestion.id)
        record(suggestion, yes: false, outcome: suggestion.notNowDoneText)
        return (true, suggestion.notNowDoneText)
    }

    func yes(_ suggestion: OllieSuggestion) async -> (ok: Bool, message: String) {
        working.insert(suggestion.id)
        failures[suggestion.id] = nil
        let result = await perform(suggestion.yes)
        working.remove(suggestion.id)
        guard result.ok else {
            let message = result.message ?? "Couldn't do that. Open it to try there."
            failures[suggestion.id] = message
            return (false, message)
        }
        markHandled(suggestion.id)
        record(suggestion, yes: true, outcome: suggestion.doneText)
        switch suggestion.yes {
        case .demo: break
        default: CompanionApprovalsMonitor.shared.refresh()
        }
        return (true, suggestion.doneText)
    }

    func open(_ suggestion: OllieSuggestion) {
        guard let store else { return }
        if case .approve(let item) = suggestion.yes { store.openApprovalItem(item); return }
        if let path = suggestion.openPath { store.openCompanion(path: path) }
    }

    private func offer(_ list: [OllieSuggestion], source: String) {
        setLatest(list, source: source)
        queue.offer(list.filter { !shown.contains($0.id) }, source: source)
    }

    private func setLatest(_ list: [OllieSuggestion], source: String) {
        if let index = latest.firstIndex(where: { $0.source == source }) { latest[index].items = list }
        else { latest.append((source, list)) }
        rebuildFeed()
    }

    private func rebuildFeed() {
        let open = latest.flatMap(\.items).filter { !queue.handled.contains($0.id) }
        if open != feed { feed = open }
        writeSnapshot()
    }

    /// A small 0600 file `ollie suggest list` reads: what is on offer and what each shop read found.
    nonisolated static var snapshotURL: URL { AppPaths.supportDirectory.appendingPathComponent("suggestions.json") }

    func writeSnapshot() {
        let object: [String: Any] = [
            "enabled": enabled,
            "watched": Self.watched,
            "feed": feed.map { ["id": $0.id, "agent": $0.agent, "shop": $0.shop, "text": $0.text] },
            "waiting_to_pop": queue.pending.count,
            "answered_this_session": history.map { ["text": $0.suggestion.text, "outcome": $0.outcome] },
            "strategy_reads": strategyReads,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Self.snapshotURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.snapshotURL.path)
    }

    private func record(_ suggestion: OllieSuggestion, yes: Bool, outcome: String) {
        history.removeAll { $0.id == suggestion.id }
        history.append(Answered(suggestion: suggestion, yes: yes, outcome: outcome, at: Date()))
        if history.count > 30 { history.removeFirst(history.count - 30) }
    }

    private func markHandled(_ id: String) {
        queue.markHandled(id)
        rebuildFeed()
        // Previews are forgotten on quit; the newest 500 real answers are remembered.
        guard !id.hasPrefix("demo:") else { return }
        handledOrder.removeAll { $0 == id }
        handledOrder.append(id)
        if handledOrder.count > 500 { handledOrder.removeFirst(handledOrder.count - 500) }
        UserDefaults.standard.set(handledOrder, forKey: Self.handledKey)
    }

    private func perform(_ action: OllieSuggestion.Action) async -> (ok: Bool, message: String?) {
        switch action {
        case .demo:
            try? await Task.sleep(nanoseconds: 700_000_000)
            return (true, nil)
        case .applyDraft(let resource, let applyText):
            // As the in-app card does: re-read the draft and send only if it is still the one shown.
            let monitor = CompanionApprovalsMonitor.shared
            if monitor.isReadOnly { return (false, CompanionWriteGuard.refusal) }
            guard let reply = await monitor.fetch(path: OllieSuggestions.strategyPath(resource: resource)),
                  reply.status == 200 else { return (false, "Couldn't reach Companion.") }
            guard OllieSuggestions.currentDraftText(reply.body) == applyText else {
                forceRefresh()
                return (false, "That proposal changed or was already set. Open it to see the latest.")
            }
            return await perform(.post(path: OllieSuggestions.strategyPath(resource: resource, "/statements"), body: ["text": applyText]))
        case .approve(let item):
            let outcome = await CompanionApprovalsActions.shared.submit(item: item, answer: "approve")
            return (outcome.remove, outcome.message)
        case .post(let path, let body):
            let monitor = CompanionApprovalsMonitor.shared
            if monitor.isReadOnly { return (false, CompanionWriteGuard.refusal) }
            guard let reply = await monitor.postJSON(path: path, body: body) else { return (false, "Couldn't reach Companion.") }
            if (200..<300).contains(reply.status) { return (true, nil) }
            let message = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any])?["message"] as? String
            return (false, message ?? "Couldn't save that.")
        }
    }
}
