import SwiftUI

struct OllieActivityView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var activity = CompanionActivity.shared
    let resource: String
    let name: String
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(OllieStyle.bg)
        .task { activity.start(resource: resource) }
        .onDisappear { activity.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { onBack() } label: {
                    Text("‹ Today").font(.system(size: 13)).foregroundStyle(OllieStyle.lime)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                OllieCompanionButton()
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Activity").font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 0)
                Text("live · 10s").font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
            }
            .foregroundStyle(OllieStyle.text)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(subline).font(.system(size: 12.5)).foregroundStyle(OllieStyle.dim)
                Spacer(minLength: 0)
                Button {
                    store.openCompanion(path: CompanionActivity.shopPagePath(resource: resource))
                } label: {
                    Text("Open activity in Companion ›")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(OllieStyle.lime)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(OllieStyle.border).frame(height: 1) }
    }

    private var subline: String {
        switch activity.state {
        case .ready(let agents):
            return name + " · " + OllieActivityModel.summary(agents: agents, lastRead: activity.lastRead)
        default:
            return name
        }
    }

    @ViewBuilder private var content: some View {
        switch activity.state {
        case .idle:
            empty("No activity available", detail: "This shop is not reporting agent activity.")
        case .loading:
            VStack(spacing: 8) {
                OllieSpinner()
                Text("Loading activity…").font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't load activity").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OllieStyle.text)
                Text("Check the Companion connection and try again.")
                    .font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
                Button("Retry") { activity.retry() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OllieStyle.lime)
            }
            .padding(24)
        case .ready(let agents):
            if agents.isEmpty {
                empty("No agents are reporting activity", detail: "New activity will appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                            if index > 0 { OllieStem() }
                            node(agent).ollieRise(index)
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(OllieStyle.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }

    private func node(_ agent: CompanionActivityAgent) -> some View {
        let node = OllieActivityNode(agent: agent)
        return Button {
            store.openCompanion(path: CompanionActivity.agentPagePath(resource: resource, agent: agent.id))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if agent.state == "working" {
                        OllieWorkingPill()
                    } else {
                        Text(node.pill)
                            .font(.system(size: 9.5, weight: .semibold)).tracking(0.4)
                            .foregroundStyle(node.tone.color)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(node.tone.color, lineWidth: 1))
                    }
                    Text(node.title).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(OllieStyle.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if agent.state == "working" {
                    HStack(spacing: 6) {
                        OllieSpinner()
                        Text(agent.current).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OllieStyle.blue).lineLimit(2)
                        if let since = agent.since, !CompanionActivityFormat.ago(since).isEmpty {
                            Text("· " + CompanionActivityFormat.ago(since))
                                .font(.system(size: 11)).foregroundStyle(OllieStyle.muted)
                        }
                    }
                } else if let waiting = agent.waiting {
                    Text("waiting on: \(waiting)" +
                         (agent.since.flatMap { CompanionActivityFormat.ago($0).isEmpty ? nil : " · " + CompanionActivityFormat.ago($0) } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(OllieStyle.amber).lineLimit(2)
                } else {
                    Text(agent.current).font(.system(size: 11)).foregroundStyle(OllieStyle.muted).lineLimit(2)
                }
                if let last = agent.lastRunSummary {
                    HStack(spacing: 4) {
                        Text("last: \(last)").lineLimit(1)
                        if let at = agent.lastRunAt, !CompanionActivityFormat.ago(at).isEmpty {
                            Text("· " + CompanionActivityFormat.ago(at))
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(OllieStyle.muted)
                }
                if !agent.sparkline.isEmpty {
                    OllieSparkline(marks: agent.sparkline).padding(.top, 2)
                }
                if let counts = node.countsText {
                    Text(counts).font(.system(size: 11)).foregroundStyle(OllieStyle.muted).lineLimit(2)
                }
                HStack {
                    Spacer(minLength: 0)
                    Text("Open in Companion ›")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(OllieStyle.lime)
                }
                .padding(.top, 1)
                if let drafts = agent.draftsWaiting, drafts > 0 {
                    Text("\(drafts) drafts waiting")
                        .font(.system(size: 10.5)).foregroundStyle(OllieStyle.amber)
                        .padding(.horizontal, 5).padding(.vertical, 0)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(OllieStyle.amber))
                        .padding(.top, 1)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OllieStyle.bg, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9)
                    .fill(node.tone.color).frame(width: 3)
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(OllieStyle.border))
            .shadow(color: agent.state == "working" ? OllieStyle.blue.opacity(0.18) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help("Open \(agent.name) in Companion")
    }
}
