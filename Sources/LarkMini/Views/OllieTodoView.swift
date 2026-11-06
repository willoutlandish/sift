import SwiftUI

struct OllieTodoView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = CompanionApprovalsMonitor.shared
    @ObservedObject private var notifications = Notifications.shared
    @ObservedObject private var activity = CompanionActivity.shared
    @State private var activityShop: CompanionTodoShop?
    @State private var banner: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Approvals", subtitle: "What needs you") {
                IconButton(symbol: "arrow.clockwise", help: "Refresh approvals") {
                    monitor.refresh()
                }
            }
            if notifications.needsNotificationPermission {
                notificationRow
            }
            summaryBar
            if let banner {
                Text(banner).font(.system(size: 11, weight: .medium)).foregroundStyle(SiftStyle.green)
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
            Rectangle().fill(SiftStyle.line).frame(height: 1)
            content
            if let error = store.errorText { ErrorBar(text: error) }
        }
        .task {
            await notifications.requestApprovalAuthorization()
            monitor.refresh()
            if case .ready(let snapshot) = monitor.state, let shop = snapshot.shops.first {
                await activity.detect(resource: shop.resource)
            }
        }
        .onChange(of: monitor.state) { _, state in
            if case .ready(let snapshot) = state, let shop = snapshot.shops.first {
                Task { await activity.detect(resource: shop.resource) }
            }
        }
        .sheet(item: $activityShop) { shop in
            ShopActivityView(shop: shop)
        }
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
                Image(systemName: "bell.badge").font(.system(size: 14)).foregroundStyle(SiftStyle.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Turn on notifications").font(.system(size: 12, weight: .semibold))
                    Text("Get approval alerts from Ollie.").font(.system(size: 10.5))
                        .foregroundStyle(SiftStyle.secondary)
                }
                Spacer(minLength: 0)
                Text(notifications.access == .denied ? "Settings" : "Turn on")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(SiftStyle.green)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(SiftStyle.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SiftStyle.green.opacity(0.25)))
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Turn on notifications")
    }

    private var summaryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(totalText).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(totalColor)
            HStack(spacing: 12) {
                Button("Open Companion") { store.openCompanion(path: "/companion/app") }
                Button("All approvals") { store.openCompanion(path: "/companion/app/approvals") }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SiftStyle.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var totalText: String {
        if case .ready(let snapshot) = monitor.state {
            return snapshot.total == 0 ? "Nothing waiting on you" : "\(snapshot.total) waiting"
        }
        return "Approvals"
    }

    private var totalColor: Color {
        if case .ready(let snapshot) = monitor.state, snapshot.total > 0 { return SiftStyle.green }
        return SiftStyle.secondary
    }

    @ViewBuilder private var content: some View {
        switch monitor.state {
        case .loading:
            PaneEmptyState(symbol: "clock", title: "Loading approvals",
                           detail: "Checking what needs you in Companion.")
        case .signedOut:
            VStack(alignment: .leading, spacing: 12) {
                PaneEmptyState(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in to Companion",
                               detail: "Ollie reads approvals from your Companion session.")
                Button("Sign in") { store.openCompanionSignIn() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SiftStyle.green).padding(.horizontal, 24)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                PaneEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load approvals",
                               detail: "Check the Companion connection and try again.")
                Button("Retry") { monitor.refresh() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SiftStyle.green).padding(.horizontal, 24)
            }
        case .ready(let snapshot):
            let shops = displayShops(snapshot)
            if shops.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if monitor.paceState == .failed {
                        Text("Pace unavailable").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                            .padding(.horizontal, 16).padding(.top, 10)
                    }
                    PaneEmptyState(symbol: "checkmark", title: "Nothing waiting on you",
                                   detail: "New approvals will appear here.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if monitor.paceState == .failed {
                            Text("Pace unavailable").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                        }
                        if snapshot.total == 0 {
                            Text("Nothing waiting on you").font(.system(size: 11)).foregroundStyle(SiftStyle.muted)
                        }
                        ForEach(shops) { shop in
                            shopSection(shop)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func displayShops(_ snapshot: CompanionTodoSnapshot) -> [CompanionTodoShop] {
        var shops = snapshot.shops
        guard monitor.paceState == .available else { return shops }
        let known = Set(shops.map(\.resource))
        for pace in monitor.pace.values where !known.contains(pace.resource) {
            shops.append(CompanionTodoShop(resource: pace.resource, name: pace.name,
                                           pending: 0, items: [], more: 0))
        }
        return shops
    }

    private func shopSection(_ shop: CompanionTodoShop) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(shop.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if activity.availability != .unavailable {
                    Button("Activity") { activityShop = shop }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(SiftStyle.green)
                        .help("See what \(shop.name)'s agents are doing")
                }
                Text("\(shop.pending)")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(SiftStyle.green)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(SiftStyle.green.opacity(0.14)))
            }
            if let pace = monitor.pace[shop.resource] {
                ShopPaceBarView(model: CompanionPaceBarModel(pace))
            }
            ForEach(shop.items) { item in
                TodoItemRow(item: item) { message in
                    banner = message
                    monitor.refresh()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if banner == message { banner = nil }
                    }
                }
            }
            if shop.more > 0 {
                Button("+\(shop.more) more") {
                    store.openCompanion(path: CompanionApprovals.clickPath(resource: shop.resource))
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(SiftStyle.green)
            }
        }
    }
}

private struct TodoItemRow: View {
    @EnvironmentObject var store: Store
    let item: CompanionTodoItem
    let onDecided: (String) -> Void

    @State private var confirming: String?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(SiftStyle.secondary).lineLimit(1)
                    Text(item.title).font(.system(size: 12)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(item.age).font(.system(size: 10)).foregroundStyle(SiftStyle.muted)
            }

            if item.canAnswer {
                HStack(spacing: 10) {
                    ForEach(item.answers, id: \.self) { answer in
                        if answer == "approve" || answer == "skip" {
                            Button(actionLabel(answer)) { confirming = answer }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(SiftStyle.green)
                                .disabled(busy || (answer == "approve" && item.disabledReason != nil))
                        } else if ["change", "send_edited"].contains(answer) {
                            Button(actionLabel(answer)) { store.openCompanion(path: item.clickPath) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(SiftStyle.green)
                        }
                    }
                    Button("Open in Companion") { store.openCompanion(path: item.clickPath) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SiftStyle.secondary)
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.mini) }
                }
            } else {
                HStack {
                    Button("Open in Companion") { store.openCompanion(path: item.clickPath) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SiftStyle.secondary)
                    Spacer(minLength: 0)
                }
            }

            if let reason = item.disabledReason {
                Text(reason).font(.system(size: 10)).foregroundStyle(SiftStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let confirming {
                confirmationBlock(confirming)
            }

            if let message {
                Text(message).font(.system(size: 10.5))
                    .foregroundStyle(message == "Approved" || message == "Declined" ? SiftStyle.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SiftStyle.line))
        .help(item.title)
    }

    private func actionLabel(_ answer: String) -> String {
        switch answer {
        case "approve": return "Approve"
        case "skip": return "Decline"
        case "change": return "Request changes"
        case "send_edited": return "Edit & send"
        default: return answer.capitalized
        }
    }

    private func confirmationBlock(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(answer == "approve" ? "Approve this item?" : "Decline this item?")
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(item.title) · \(item.label)").font(.system(size: 10.5))
                .foregroundStyle(SiftStyle.secondary).lineLimit(2)
            if let preview = item.payloadPreview {
                Text(preview).font(.system(size: 10.5)).foregroundStyle(SiftStyle.secondary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(answer == "approve" ? "Confirm approve" : "Confirm decline") {
                    submit(answer)
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SiftStyle.green).disabled(busy)
                Button("Cancel") { confirming = nil }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(SiftStyle.secondary).disabled(busy)
            }
        }
        .padding(8)
        .background(SiftStyle.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SiftStyle.line))
    }

    private func submit(_ answer: String) {
        guard !busy else { return }
        busy = true
        message = nil
        Task { @MainActor in
            let outcome = await CompanionApprovalsActions.shared.submit(item: item, answer: answer)
            busy = false
            confirming = nil
            if outcome.remove {
                onDecided(outcome.message)
            } else {
                message = outcome.message
            }
        }
    }
}

private struct ShopPaceBarView: View {
    let model: CompanionPaceBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(model.text).font(.system(size: 9.5)).foregroundStyle(SiftStyle.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(model.statusLabel).font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(model.tone.color)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(SiftStyle.line).frame(height: 5)
                    Capsule().fill(model.tone.color)
                        .frame(width: max(0, geometry.size.width * model.actualFraction), height: 5)
                    if let tick = model.expectedFraction {
                        Rectangle().fill(Color.white.opacity(0.7)).frame(width: 1, height: 9)
                            .offset(x: min(max(0, geometry.size.width * tick), geometry.size.width - 1))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 9)
        }
    }
}

private extension CompanionPaceTone {
    var color: Color {
        switch self {
        case .green: return SiftStyle.green
        case .red: return Color.orange
        case .grey: return SiftStyle.muted
        }
    }
}
