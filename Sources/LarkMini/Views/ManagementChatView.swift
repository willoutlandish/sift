import SwiftUI

/// Pinned under Ollie in the rail: the agents' ideas, waiting count on the badge.
struct ManagementRailItem: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var center = OllieSuggestionCenter.shared

    var body: some View {
        Button { store.showManagement() } label: {
            VStack(spacing: 4) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(SiftStyle.green)
                    .frame(width: 32, height: 26)
                    .overlay(alignment: .topTrailing) {
                        if !center.feed.isEmpty {
                            Text("\(center.feed.count)").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                                .background(SiftStyle.green, in: Capsule())
                                .offset(x: 6, y: -5)
                        }
                    }
                Text("Manage").font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 48, height: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(store.pane.railItem == .management ? SiftStyle.raised : .clear))
        }
        .buttonStyle(.plain)
        .help("Management: what Ollie's agents want to do")
        .accessibilityLabel("Management chat" + (center.feed.isEmpty ? "" : ", \(center.feed.count) waiting"))
    }
}

/// Reads like the shop's Management chat: Ollie's agents say what they'd do, you say yes or not now.
struct ManagementChatView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var center = OllieSuggestionCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Management",
                       subtitle: center.feed.isEmpty ? "Nothing waiting on you" : "\(center.feed.count) idea\(center.feed.count == 1 ? "" : "s") waiting on you") {
                IconButton(symbol: "arrow.clockwise", help: "Ask the agents again") { center.forceRefresh() }
            }
            Rectangle().fill(SiftStyle.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(center.history) { answered in
                            AnsweredRow(answered: answered)
                        }
                        if center.feed.isEmpty && center.history.isEmpty {
                            empty
                        }
                        ForEach(center.feed) { suggestion in
                            SuggestionMessage(suggestion: suggestion).id(suggestion.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: center.feed.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FaceIcon(size: 24)
                Text("Ollie").font(.system(size: 12, weight: .semibold))
            }
            Text("When the Strategy Manager, Creator Manager or another agent wants to do something, I'll say it here and pop out beside my face.")
                .font(.system(size: 13)).foregroundStyle(SiftStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(SiftStyle.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// One agent message with its Yes / Not now, like Ollie's card in the Companion chat.
struct SuggestionMessage: View {
    let suggestion: OllieSuggestion
    @EnvironmentObject var store: Store
    @ObservedObject private var center = OllieSuggestionCenter.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FaceIcon(size: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text((suggestion.isNotice ? "Needs a look · " : "") + suggestion.byline)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(suggestion.isNotice ? Color.orange : SiftStyle.green)
                Text(suggestion.text).font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = suggestion.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure = center.failures[suggestion.id] {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11))
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if center.working.contains(suggestion.id) {
                        ProgressView().controlSize(.small)
                        Text("On it…").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                    } else {
                        Button { center.answerFromFeed(suggestion, yes: true) } label: {
                            Text(suggestion.yesLabel).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(SiftStyle.green, in: Capsule()).foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        Button { center.answerFromFeed(suggestion, yes: false) } label: {
                            Text(suggestion.notNowLabel).font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(SiftStyle.raised, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        Button { center.open(suggestion) } label: {
                            Text("Open").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SiftStyle.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SiftStyle.green.opacity(0.25)))
        }
        .accessibilityElement(children: .contain)
    }
}

/// Answered this session: the idea, then your reply on the right, as in a chat.
struct AnsweredRow: View {
    let answered: OllieSuggestionCenter.Answered

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                FaceIcon(size: 22).opacity(0.7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(answered.suggestion.byline).font(.system(size: 10, weight: .semibold)).foregroundStyle(SiftStyle.muted)
                    Text(answered.suggestion.text).font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                        .lineLimit(2)
                }
            }
            HStack {
                Spacer(minLength: 40)
                Label(answered.outcome, systemImage: answered.yes ? "checkmark" : (answered.suggestion.isNotice ? "hand.raised" : "clock"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background((answered.yes ? SiftStyle.green.opacity(0.22) : SiftStyle.raised), in: Capsule())
                    .foregroundStyle(answered.yes ? SiftStyle.green : SiftStyle.secondary)
            }
        }
    }
}
