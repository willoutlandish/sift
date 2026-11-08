import SwiftUI

struct OllieApprovalsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var monitor = CompanionApprovalsMonitor.shared
    let resource: String?
    let name: String?
    let onBack: () -> Void

    @State private var showAll: Bool
    @State private var selectedCategory: String?
    @State private var banner: String?

    init(resource: String?, name: String?, onBack: @escaping () -> Void) {
        self.resource = resource
        self.name = name
        self.onBack = onBack
        _showAll = State(initialValue: resource == nil)
    }

    private var snapshot: CompanionTodoSnapshot? {
        if case .ready(let snapshot) = monitor.state { return snapshot }
        return nil
    }

    private var model: OllieApprovalsModel {
        OllieApprovalsModel(snapshot: snapshot,
                            shopResource: showAll ? nil : resource,
                            category: selectedCategory)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(OllieStyle.bg)
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
                Text("Waiting on you").font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(model.totalHere) here · \(model.totalAll) all shops")
                    .font(.system(size: 11.5)).foregroundStyle(OllieStyle.dim)
            }
            .foregroundStyle(OllieStyle.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("This shop", selected: !showAll) {
                        showAll = false
                        selectedCategory = nil
                    }
                    chip("All shops", selected: showAll) {
                        showAll = true
                        selectedCategory = nil
                    }
                    ForEach(model.categories) { category in
                        chip(category.label, selected: selectedCategory == category.key) {
                            selectedCategory = selectedCategory == category.key ? nil : category.key
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(OllieStyle.border).frame(height: 1) }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color(red: 20/255, green: 32/255, blue: 10/255) : OllieStyle.dim)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(selected ? OllieStyle.lime : OllieStyle.card2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if case .signedOut = monitor.state, snapshot == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in to Companion").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OllieStyle.text)
                Text("Ollie reads approvals from your Companion session.")
                    .font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
                Button("Sign in") { store.openCompanionSignIn() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OllieStyle.lime)
            }.padding(24)
        } else if case .failed = monitor.state, snapshot == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't load approvals").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OllieStyle.text)
                Text("Check the Companion connection and try again.")
                    .font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
                Button("Retry") { monitor.refresh() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OllieStyle.lime)
            }.padding(24)
        } else if snapshot == nil {
            VStack(spacing: 8) {
                OllieSpinner()
                Text("Loading approvals…").font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let banner {
                        Text(banner).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(OllieStyle.green)
                            .padding(.horizontal, 2).padding(.top, 6)
                    }
                    if monitor.isReadOnly {
                        Text(CompanionWriteGuard.refusal)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(OllieStyle.amber)
                            .padding(.horizontal, 2).padding(.top, 6)
                    }
                    if let item = model.doThisFirst {
                        doThisFirst(item).id(item.id)
                    }
                    ForEach(model.batches) { batch in
                        batchRow(batch).id(batch.id)
                    }
                    ForEach(Array(model.newer.enumerated()), id: \.element.id) { index, item in
                        approvalRow(item).id(item.id).ollieRise(index)
                    }
                    if !model.older.isEmpty {
                        Text("Older").font(.system(size: 11)).tracking(0.4)
                            .foregroundStyle(OllieStyle.dim)
                            .padding(.horizontal, 2).padding(.top, 6)
                        ForEach(Array(model.older.enumerated()), id: \.element.id) { index, item in
                            approvalRow(item).id(item.id).ollieRise(index)
                        }
                    }
                    if model.doThisFirst == nil && model.batches.isEmpty && model.newer.isEmpty && model.older.isEmpty {
                        Text("Nothing waiting on you").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OllieStyle.text).padding(.top, 18)
                        Text("New approvals will appear here.")
                            .font(.system(size: 11)).foregroundStyle(OllieStyle.dim)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
    }

    private func doThisFirst(_ item: CompanionTodoItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DO THIS FIRST").font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(OllieStyle.lime)
            OllieApprovalItemRow(item: item, highlight: true, readOnly: monitor.isReadOnly) { message in
                banner = message
                monitor.refresh()
            }
        }
        .padding(10)
        .background(LinearGradient(colors: [OllieStyle.lime.opacity(0.12), OllieStyle.lime.opacity(0.03)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: OllieStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: OllieStyle.cardRadius)
            .strokeBorder(OllieStyle.lime.opacity(0.35)))
    }

    private func batchRow(_ batch: OllieApprovalBatch) -> some View {
        HStack(spacing: 6) {
            Text(batch.label).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(OllieStyle.text)
            tag(batch.items.first)
            Spacer(minLength: 0)
            Button("Review all ›") { store.openCompanion(path: "/companion/app/approvals") }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OllieStyle.lime)
        }
        .padding(10)
        .background(OllieStyle.card2, in: RoundedRectangle(cornerRadius: OllieStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: OllieStyle.cardRadius)
            .strokeBorder(OllieStyle.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func approvalRow(_ item: CompanionTodoItem) -> some View {
        OllieApprovalItemRow(item: item, highlight: false, readOnly: monitor.isReadOnly) { message in
            banner = message
            monitor.refresh()
        }
    }

    private func tag(_ item: CompanionTodoItem?) -> some View {
        let label = item?.categoryLabel.uppercased() ?? ""
        let key = item?.categoryKey.lowercased() ?? ""
        let tone: OllieTone = key.contains("money") || key.contains("budget") || key.contains("incentive")
            ? .amber : (key.contains("creator") || key.contains("sample") ? .blue : .muted)
        return Text(label)
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.2)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tone.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct OllieApprovalItemRow: View {
    @EnvironmentObject var store: Store
    let item: CompanionTodoItem
    let highlight: Bool
    let readOnly: Bool
    let onChanged: (String) -> Void

    @State private var confirming: (id: String, answer: String)?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OllieStyle.text).fixedSize(horizontal: false, vertical: true)
                tag
            }
            if let reason = item.reason {
                Text(reason).font(.system(size: 12)).foregroundStyle(OllieStyle.dim)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text(item.label).foregroundStyle(OllieStyle.muted)
                Text("· \(item.age)").foregroundStyle(OllieStyle.muted)
                if OllieApprovalsModel.isOverdue(item) {
                    Text("· overdue").foregroundStyle(OllieStyle.red)
                }
            }
            .font(.system(size: 11))

            if let draft = item.payloadPreview {
                Text(draft).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if !item.recipients.isEmpty {
                Text("To: \(item.recipients.joined(separator: ", "))").font(.system(size: 11))
            }
            if readOnly {
                Button("Open in Companion") { store.openCompanion(path: item.clickPath) }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(OllieStyle.dim)
            } else if item.canAnswer {
                HStack(spacing: 8) {
                    ForEach(item.answers, id: \.self) { answer in
                        if (answer == "approve" && item.canApprove) || answer == "skip" {
                            Button(label(answer)) { confirming = (item.id, answer) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(answer == "approve" ? OllieStyle.lime : OllieStyle.dim)
                                .disabled(busy || (answer == "approve" && item.disabledReason != nil))
                        } else if ["change", "send_edited"].contains(answer) {
                            Button(label(answer)) { store.openCompanion(path: item.clickPath) }
                                .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(OllieStyle.dim)
                        }
                    }
                    Button("Open in Companion") { store.openCompanion(path: item.clickPath) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(OllieStyle.dim)
                    Spacer(minLength: 0)
                    if busy { OllieSpinner() }
                }
            } else {
                Button("Open in Companion") { store.openCompanion(path: item.clickPath) }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(OllieStyle.dim)
            }
            if let reason = item.disabledReason {
                Text(reason).font(.system(size: 10)).foregroundStyle(OllieStyle.muted)
            }
            if let confirming, confirming.id == item.id, !readOnly {
                confirmBlock(confirming.answer)
            }
            if let message {
                Text(message).font(.system(size: 10.5))
                    .foregroundStyle(message.hasPrefix("Approved") || message.hasPrefix("Declined")
                        ? OllieStyle.green : OllieStyle.amber)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OllieStyle.card, in: RoundedRectangle(cornerRadius: OllieStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: OllieStyle.cardRadius)
            .strokeBorder(highlight ? OllieStyle.lime.opacity(0.35) : OllieStyle.border))
        .textSelection(.enabled)
        .help(item.title)
    }

    private var tag: some View {
        let key = item.categoryKey.lowercased()
        let tone: OllieTone = key.contains("money") || key.contains("budget") || key.contains("incentive")
            ? .amber : (key.contains("creator") || key.contains("sample") ? .blue : .muted)
        return Text(item.categoryLabel.uppercased())
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.2)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tone.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }

    private func label(_ answer: String) -> String {
        switch answer {
        case "approve": return "Approve"
        case "skip": return "Decline"
        case "change": return "Request changes"
        case "send_edited": return "Edit & send"
        default: return answer.capitalized
        }
    }

    private func confirmBlock(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(answer == "approve" ? "Approve this item?" : "Decline this item?")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(OllieStyle.text)
            Text("\(item.title) · \(item.label)").font(.system(size: 10.5))
                .foregroundStyle(OllieStyle.dim).lineLimit(2)
            if let preview = item.payloadPreview {
                Text(preview).font(.system(size: 10.5)).foregroundStyle(OllieStyle.dim)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(answer == "approve" ? "Confirm approve" : "Confirm decline") { submit(answer) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OllieStyle.lime).disabled(busy)
                Button("Cancel") { confirming = nil }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(OllieStyle.dim).disabled(busy)
            }
        }
        .padding(8)
        .background(OllieStyle.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(OllieStyle.border))
    }

    private func submit(_ answer: String) {
        guard confirming?.id == item.id, confirming?.answer == answer else {
            confirming = nil
            return
        }
        guard !busy else { return }
        busy = true
        message = nil
        Task { @MainActor in
            let outcome = await CompanionApprovalsActions.shared.submit(item: item, answer: answer)
            busy = false
            confirming = nil
            if outcome.remove {
                onChanged(outcome.message)
            } else {
                message = outcome.message
            }
        }
    }
}
