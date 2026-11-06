import SwiftUI

struct ShopActivityView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var activity = CompanionActivity.shared
    let shop: CompanionTodoShop

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity").font(.system(size: 20, weight: .semibold))
                    Text(shop.name).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", help: "Close Activity") { dismiss() }
            }
            .padding(.horizontal, 16).frame(height: 70)
            Rectangle().fill(SiftStyle.line).frame(height: 1)
            content
        }
        .frame(minWidth: 440, minHeight: 460)
        .task { activity.start(resource: shop.resource) }
        .onDisappear { activity.stop() }
    }

    @ViewBuilder private var content: some View {
        switch activity.state {
        case .idle:
            PaneEmptyState(symbol: "waveform.path.ecg", title: "No activity available",
                           detail: "This shop has no live agent activity to show.")
        case .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading activity…").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                PaneEmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load activity",
                               detail: "Check the Companion connection and try again.")
                Button("Retry") { activity.retry() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SiftStyle.green).padding(.horizontal, 24)
            }
        case .ready(let agents):
            if agents.isEmpty {
                PaneEmptyState(symbol: "checkmark", title: "No agents are reporting activity",
                               detail: "New activity will appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(agents) { agent in
                            agentRow(agent)
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func agentRow(_ agent: CompanionActivityAgent) -> some View {
        Button {
            store.openCompanion(path: CompanionActivity.agentPagePath(resource: shop.resource, agent: agent.id))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(agent.state).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(agent.state == "failed" ? Color.orange : SiftStyle.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.current).font(.system(size: 12)).lineLimit(2)
                    if let since = agent.since, !CompanionActivityFormat.ago(since).isEmpty {
                        Text(CompanionActivityFormat.ago(since)).font(.system(size: 10))
                            .foregroundStyle(SiftStyle.muted).fixedSize()
                    }
                }
                if let waiting = agent.waiting {
                    Text("Waiting on: \(waiting)").font(.system(size: 10.5))
                        .foregroundStyle(SiftStyle.secondary).lineLimit(1)
                }
                ForEach(Array(agent.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 10.5)).foregroundStyle(SiftStyle.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SiftStyle.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SiftStyle.line))
        }
        .buttonStyle(.plain)
        .help("Open \(agent.name) in Companion")
    }
}
