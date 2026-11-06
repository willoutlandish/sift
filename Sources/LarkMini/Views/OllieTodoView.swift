import SwiftUI

struct OllieTodoView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = CompanionApprovalsMonitor.shared
    @ObservedObject private var notifications = Notifications.shared
    @ObservedObject private var activity = CompanionActivity.shared
    @State private var activityShop: CompanionTodoShop?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Ollie", subtitle: "What needs you") {
                IconButton(symbol: "arrow.clockwise", help: "Refresh to-dos") {
                    monitor.refresh()
                }
            }
            if notifications.needsNotificationPermission {
                notificationRow
            }
            summaryBar
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
        return "Ollie to-dos"
    }

    private var totalColor: Color {
        if case .ready(let snapshot) = monitor.state, snapshot.total > 0 { return SiftStyle.green }
        return SiftStyle.secondary
    }

    @ViewBuilder private var content: some View {
        switch monitor.state {
        case .loading:
            PaneEmptyState(symbol: "clock", title: "Loading your to-dos",
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
                PaneEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load your to-dos",
                               detail: "Check the Companion connection and try again.")
                Button("Retry") { monitor.refresh() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SiftStyle.green).padding(.horizontal, 24)
            }
        case .ready(let snapshot):
            if snapshot.shops.isEmpty {
                PaneEmptyState(symbol: "checkmark", title: "Nothing waiting on you",
                               detail: "New approvals will appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot.shops) { shop in
                            shopSection(shop)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .scrollIndicators(.never)
            }
        }
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
            ForEach(shop.items) { item in
                Button {
                    store.openCompanion(path: item.clickPath)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(SiftStyle.secondary).lineLimit(1)
                            Text(item.title).font(.system(size: 12)).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Text(item.age).font(.system(size: 10)).foregroundStyle(SiftStyle.muted)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SiftStyle.line))
                }
                .buttonStyle(.plain)
                .help(item.title)
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
