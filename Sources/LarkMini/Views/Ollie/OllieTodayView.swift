import SwiftUI

struct OllieTodayView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = CompanionApprovalsMonitor.shared
    @ObservedObject private var notifications = Notifications.shared
    @ObservedObject private var activity = CompanionActivity.shared
    let onActivity: (OllieTodayShop) -> Void
    let onApprovals: (OllieTodayShop) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if notifications.needsNotificationPermission {
                notificationRow
            }
            errorStrips
            content
        }
        .background(OllieStyle.bg)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
        })
        .task {
            await notifications.requestApprovalAuthorization()
            monitor.refresh()
            loadSummaries()
        }
        .onChange(of: monitor.state) { _, _ in loadSummaries() }
        .onChange(of: monitor.pace) { _, _ in loadSummaries() }
    }

    private var snapshot: CompanionTodoSnapshot? {
        if case .ready(let snapshot) = monitor.state { return snapshot }
        return nil
    }

    private var model: OllieTodayModel {
        OllieTodayModel(pace: monitor.pace, paceState: monitor.paceState,
                        snapshot: snapshot, activity: activity.summaries,
                        totals: monitor.paceTotals)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today").font(.system(size: 20, weight: .semibold))
            Spacer(minLength: 0)
            OllieCompanionButton()
            Text(Self.dateText()).font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
        }
        .foregroundStyle(OllieStyle.text)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(OllieStyle.border).frame(height: 1) }
    }

    private var notificationRow: some View {
        Button {
            Task {
                if notifications.access == .denied {
                    notifications.openNotificationSettings()
                } else {
                    await notifications.requestApprovalAuthorization()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge").font(.system(size: 13)).foregroundStyle(OllieStyle.lime)
                Text("Turn on notifications").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(notifications.access == .denied ? "Settings" : "Turn on")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(OllieStyle.lime)
            }
            .foregroundStyle(OllieStyle.text)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(OllieStyle.card)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var errorStrips: some View {
        if case .signedOut = monitor.state {
            errorStrip("Sign in to Companion", action: "Sign in") { store.openCompanionSignIn() }
        } else if case .failed = monitor.state {
            errorStrip("Couldn't load approvals", action: "Retry") { monitor.refresh() }
        }
        if monitor.paceState == .failed {
            errorStrip("Pace unavailable", action: "Retry") { monitor.refresh() }
        }
        if !model.shops.isEmpty,
           model.shops.allSatisfy({ if case .failed? = activity.summaries[$0.resource] { return true }; return false }) {
            errorStrip("Activity unavailable", action: "Retry") { loadSummaries(force: true) }
        }
    }

    private func errorStrip(_ text: String, action: String, run: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 11)).foregroundStyle(OllieStyle.amber)
            Spacer(minLength: 0)
            Button(action, action: run)
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(OllieStyle.lime)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(OllieStyle.card.opacity(0.7))
    }

    @ViewBuilder private var content: some View {
        if case .signedOut = monitor.state, model.shops.isEmpty {
            signInState
        } else if model.shops.isEmpty {
            VStack(spacing: 8) {
                Text(monitor.state == .loading ? "Loading today…" : "No shops to show")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(OllieStyle.text)
                if monitor.state != .loading {
                    Text("Pace and approvals will appear here when Companion has them.")
                        .font(.system(size: 11)).foregroundStyle(OllieStyle.dim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(model.summary)
                        .font(.system(size: 12.5)).foregroundStyle(OllieStyle.dim)
                        .padding(.horizontal, 2).padding(.top, 8).padding(.bottom, 2)
                    ForEach(Array(model.allProgress.enumerated()), id: \.element.id) { index, progress in
                        allShopsCard(progress).ollieRise(index)
                    }
                    ForEach(Array(model.shops.enumerated()), id: \.element.id) { index, shop in
                        card(shop).ollieRise(index + model.allProgress.count)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
    }

    private var signInState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Companion").font(.system(size: 17, weight: .medium))
                .foregroundStyle(OllieStyle.text)
            Text("Ollie reads your shops, pace and approvals from the Companion session.")
                .font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
            Button("Sign in") { store.openCompanionSignIn() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OllieStyle.lime)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }

    private func card(_ shop: OllieTodayShop) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(shop.name).font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(OllieStyle.text).lineLimit(1)
                Spacer(minLength: 0)
                if let pill = shop.pill {
                    Text(pill.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pill.tone.color)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(pill.tone.color.opacity(0.15), in: Capsule())
                }
            }
            if let bar = shop.bar, shop.pace?.goal != nil, shop.pace?.mtd != nil {
                OlliePaceBar(model: bar, tone: shop.pill?.tone ?? .muted)
                    .padding(.top, 9)
                HStack {
                    Text("\(Int((shop.pace?.progressPct ?? 0).rounded()))% of \(CompanionPace.compactMoney(shop.pace?.goal, currency: shop.pace?.targetCurrency)) month target")
                    Spacer(minLength: 0)
                    Text("expected \(CompanionPace.compactMoney(shop.pace?.expectedByToday, currency: shop.pace?.currency))")
                }
                .font(.system(size: 11.5)).foregroundStyle(OllieStyle.dim)
                .padding(.top, 4)
            }
            HStack(spacing: 6) {
                if let summary = shop.activity, summary != .unavailable {
                    switch summary {
                    case .ready(_, let working):
                        actionButton(title: "Activity",
                                     value: working > 0 ? "\(working) ›" : "idle ›",
                                     valueColor: working > 0 ? OllieStyle.blue : OllieStyle.dim,
                                     spinner: working > 0) { onActivity(shop) }
                    case .failed:
                        actionButton(title: "Activity", value: "›", valueColor: OllieStyle.dim) { onActivity(shop) }
                    case .unavailable:
                        EmptyView()
                    }
                } else if let working = shop.portfolioWorking, working > 0 {
                    actionButton(title: "Activity", value: "\(working) on ›",
                                 valueColor: OllieStyle.dim, spinner: false) { onActivity(shop) }
                } else if shop.activity == nil {
                    actionButton(title: "Activity", value: "›", valueColor: OllieStyle.dim) { onActivity(shop) }
                }
                actionButton(title: "Waiting on you",
                             value: shop.pending.map { "\($0) ›" } ?? "›",
                             valueColor: OllieStyle.lime) { onApprovals(shop) }
            }
            .padding(.top, 9)
        }
        .padding(11)
        .background(OllieStyle.card, in: RoundedRectangle(cornerRadius: OllieStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: OllieStyle.cardRadius).strokeBorder(OllieStyle.border))
    }

    private func allShopsCard(_ progress: OllieAllShopProgress) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(progress.label).font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(OllieStyle.text).lineLimit(1)
                Spacer(minLength: 0)
                if let pill = progress.pill {
                    Text(pill.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pill.tone.color)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(pill.tone.color.opacity(0.15), in: Capsule())
                }
            }
            OlliePaceBar(model: progress.bar, tone: progress.pill?.tone ?? .muted)
                .padding(.top, 9)
            HStack {
                if let mtd = progress.pace.mtd {
                    Text("\(Int((progress.pace.progressPct ?? 0).rounded()))% of \(CompanionPace.compactMoney(progress.pace.goal, currency: progress.currency)) month target")
                } else if progress.pace.goal != nil {
                    Text("No sales data · goal \(CompanionPace.compactMoney(progress.pace.goal, currency: progress.currency))")
                } else {
                    Text("No sales data")
                }
                Spacer(minLength: 0)
                if let expected = progress.pace.expectedByToday {
                    Text("expected \(CompanionPace.compactMoney(expected, currency: progress.currency))")
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(OllieStyle.dim)
            .padding(.top, 4)
            if let through = CompanionPace.metricsText(progress.pace.metricsThrough) {
                Text("numbers to \(through)")
                    .font(.system(size: 10.5)).foregroundStyle(OllieStyle.muted)
                    .padding(.top, 2)
            }
        }
        .padding(11)
        .background(OllieStyle.card, in: RoundedRectangle(cornerRadius: OllieStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: OllieStyle.cardRadius).strokeBorder(OllieStyle.lime.opacity(0.35)))
        .contentShape(RoundedRectangle(cornerRadius: OllieStyle.cardRadius))
        .onTapGesture { store.openCompanion(path: "/companion/app") }
    }

    private func actionButton(title: String, value: String, valueColor: Color,
                              spinner: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if spinner { OllieSpinner() }
                Text(title).font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
                Spacer(minLength: 0)
                Text(value).font(.system(size: 12, weight: .bold)).foregroundStyle(valueColor)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(OllieStyle.card2, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(OllieStyle.border))
        }
        .buttonStyle(.plain)
    }

    private func loadSummaries(force: Bool = false) {
        var resources = Set(monitor.pace.keys)
        if let snapshot {
            resources.formUnion(snapshot.shops.map(\.resource))
        }
        let list = Array(resources)
        Task {
            if force {
                for resource in list { activity.clearSummary(resource) }
            }
            await activity.loadSummaries(resources: list)
        }
    }

    private static func dateText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: Date())
    }
}

private struct OlliePaceBar: View {
    @Environment(\.siftReduceMotion) private var reduceMotion
    let model: CompanionPaceBarModel
    let tone: OllieTone
    @State private var grown = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(OllieStyle.card2).frame(height: 7)
                Capsule().fill(tone.color)
                    .frame(width: geometry.size.width * (grown || reduceMotion ? model.actualFraction : 0), height: 7)
                if let tick = model.expectedFraction {
                    Rectangle().fill(Color.white.opacity(0.85)).frame(width: 2, height: 15)
                        .offset(x: min(max(0, geometry.size.width * tick - 1), geometry.size.width - 2), y: -4)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 15)
        .onAppear {
            guard !reduceMotion else { grown = true; return }
            withAnimation(.easeOut(duration: 0.8)) { grown = true }
        }
    }
}
