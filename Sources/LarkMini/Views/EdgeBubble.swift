import AppKit
import Combine
import SwiftUI

/// A soft thought bubble beside the collapsed head: a new Lark arrival or a genuine Control need.
struct EdgeBubble: Equatable, Identifiable {
    enum Target: Equatable { case chat(String), inbox, control, suggestion }

    var id = UUID()
    var target: Target
    var title: String
    var text: String
    var names: [String] = []
    var count = 1
    var suggestion: OllieSuggestion? = nil

    /// A burst of arrivals coalesces into one bubble; a Control need is never covered by chatter.
    static func arrival(_ current: EdgeBubble?, chatId: String, name: String, text: String) -> EdgeBubble {
        // A suggestion steps aside for a new message rather than merging with it.
        let current = current?.target == .suggestion ? nil : current
        guard let current, current.target != .control else {
            return current ?? EdgeBubble(target: .chat(chatId), title: name, text: text, names: [name])
        }
        let names = current.names.contains(name) ? current.names : current.names + [name]
        let count = current.count + 1
        let others = names.count > 2 ? " +\(names.count - 2)" : ""
        return EdgeBubble(id: current.id, target: names.count == 1 ? .chat(chatId) : .inbox,
                          title: names.count == 1 ? "\(name) · \(count) new"
                              : "\(count) new · " + names.prefix(2).joined(separator: ", ") + others,
                          text: text, names: names, count: count)
    }
}

/// Ollie's own chat-bird mark, drawn in white: a speech bubble with a wing.
struct ChatBirdMark: View {
    var size: CGFloat = 26

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 24
            var bird = Path()
            bird.addEllipse(in: CGRect(x: 3 * s, y: 4 * s, width: 18 * s, height: 14 * s))
            bird.move(to: CGPoint(x: 7 * s, y: 15 * s))
            bird.addLine(to: CGPoint(x: 5 * s, y: 21 * s))
            bird.addLine(to: CGPoint(x: 11.5 * s, y: 16.8 * s))
            bird.closeSubpath()
            context.fill(bird, with: .color(.white))
            var wing = Path()
            wing.move(to: CGPoint(x: 8 * s, y: 12 * s))
            wing.addQuadCurve(to: CGPoint(x: 16.5 * s, y: 8.5 * s), control: CGPoint(x: 11 * s, y: 14.5 * s))
            context.stroke(wing, with: .color(ChatBirdMark.tint), style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 16.6 * s, y: 7.4 * s, width: 1.6 * s, height: 1.6 * s)), with: .color(ChatBirdMark.tint))
        }
        .frame(width: size * 0.62, height: size * 0.62)
        .frame(width: size, height: size)
        .background(ChatBirdMark.tint, in: Circle())
        .accessibilityHidden(true)
    }

    static let tint = Color(red: 0.20, green: 0.44, blue: 0.98)
}

/// A rounded cloud with a few soft bumps, merged into one outline; static, so it costs nothing at rest.
struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var cloud = Path(roundedRect: rect.insetBy(dx: 0, dy: 7), cornerRadius: 22, style: .continuous)
        for (x, d) in [(0.24, 30.0), (0.5, 36.0), (0.74, 28.0)] {
            cloud = cloud.union(Path(ellipseIn: CGRect(x: rect.minX + rect.width * x - d / 2, y: rect.minY, width: d, height: d)))
        }
        for (x, d) in [(0.36, 24.0), (0.62, 22.0)] {
            cloud = cloud.union(Path(ellipseIn: CGRect(x: rect.minX + rect.width * x - d / 2, y: rect.maxY - d, width: d, height: d)))
        }
        return cloud
    }
}

struct EdgeBubbleView: View {
    let bubble: EdgeBubble
    @EnvironmentObject var store: Store
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            HStack(spacing: 10) {
                if bubble.target == .control {
                    ControlMark(size: 26).background(SiftStyle.raised, in: Circle())
                } else {
                    ChatBirdMark(size: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(bubble.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(bubble.text).font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                        .lineLimit(hovering ? 3 : 1).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 190, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(CloudShape().fill(SiftStyle.surface.opacity(0.97)))
            .overlay(CloudShape().stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            // Trailing thought dots toward the head.
            VStack(spacing: 3) {
                Circle().fill(SiftStyle.surface.opacity(0.97)).frame(width: 8, height: 8)
                Circle().fill(SiftStyle.surface.opacity(0.97)).frame(width: 5, height: 5).offset(x: 5)
            }
            .padding(.bottom, 2)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            store.holdBubble(inside)
        }
        .onTapGesture { store.openBubble() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens it in Ollie")
    }
}

/// One spring on arrival, then still; Reduce Motion fades only.
struct EdgeBubbleHost: View {
    @EnvironmentObject var store: Store
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            if let bubble = store.bubble {
                Group {
                    if let suggestion = bubble.suggestion {
                        SuggestionBubbleView(suggestion: suggestion)
                    } else {
                        EdgeBubbleView(bubble: bubble)
                    }
                }
                    .id(bubble.id)
                    .transition(reduceMotion ? .opacity
                        : .scale(scale: 0.55, anchor: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.62),
                   value: store.bubble?.id)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

/// A transparent window beside the collapsed head that never takes focus.
@MainActor
final class EdgeBubbleController {
    private let store: Store
    private let panel: NSPanel
    private var watch: AnyCancellable?
    private var keyWatch: [NSObjectProtocol] = []
    private static let size = NSSize(width: 300, height: 130)
    private static let suggestionSize = NSSize(width: 360, height: 230)
    private var size: NSSize { store.bubble?.suggestion == nil ? Self.size : Self.suggestionSize }

    init(store: Store) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: EdgeBubbleHost().environmentObject(store))
        host.sizingOptions = []
        panel.contentView = host
        watch = store.$bubble.combineLatest(store.$isExpanded)
            .receive(on: RunLoop.main)
            .sink { [weak self] bubble, expanded in
                MainActor.assumeIsolated { self?.refresh(expanded: expanded) }
            }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(expanded: self?.store.isExpanded ?? true) }
            }
            keyWatch.append(token)
        }
    }

    private func refresh(expanded: Bool) {
        // Suggestions have their own switch (`ollie suggest off`); Lark pop-ups do not gate them.
        let allowed = store.bubble?.suggestion != nil ? OllieSuggestionCenter.shared.enabled : store.settings.showLarkPopups
        // A bubble speaks for the head: with no head on screen (hidden, or --background-check), none shows.
        let visible = store.bubble != nil
            && PanelBridge.shared.panel?.isVisible == true
            && !expanded
            && allowed
            && !PanelBridge.shared.isFocused
            && CompanionWindowController.shared.window?.isKeyWindow != true
        update(visible: visible)
    }

    private func update(visible: Bool) {
        guard visible else {
            // Let the fade finish, then drop the window so a resting edge costs nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.store.bubble == nil || self.store.isExpanded else { return }
                self.panel.orderOut(nil)
            }
            return
        }
        guard let head = PanelBridge.shared.panel?.frame,
              let screen = (PanelBridge.shared.panel?.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = self.size
        let x = head.midX < screen.midX ? head.maxX - 6 : head.minX - size.width + 6
        // A suggestion's card sits with its foot at the head, so the thought dots point at the face.
        let lift: CGFloat = store.bubble?.suggestion == nil ? 34 : 60
        var frame = NSRect(origin: NSPoint(x: x, y: head.midY - lift), size: size)
        frame.origin.y = min(max(frame.minY, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }
}

/// "I think you should… want me to?" An agent's proposal said from Ollie's face, with a yes.
/// Yes runs the same Companion route as the in-app card; Not now records it there too.
struct SuggestionBubbleView: View {
    let suggestion: OllieSuggestion
    @EnvironmentObject var store: Store
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    FaceIcon(size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ollie has an idea").font(.system(size: 11, weight: .semibold)).foregroundStyle(SiftStyle.green)
                        Text(suggestion.byline).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { store.answerSuggestion(yes: false) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SiftStyle.muted).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(store.suggestionStatus == .idle ? suggestion.notNowLabel : "Close")
                    .accessibilityLabel(store.suggestionStatus == .idle ? suggestion.notNowLabel : "Close")
                }
                Text(suggestion.text).font(.system(size: 13, weight: .medium))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let detail = suggestion.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(SiftStyle.secondary)
                        .lineLimit(hovering ? 4 : 2).fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            .frame(width: 300, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SiftStyle.surface.opacity(0.98)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(SiftStyle.green.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
            VStack(spacing: 3) {
                Circle().fill(SiftStyle.surface.opacity(0.98)).frame(width: 9, height: 9)
                Circle().fill(SiftStyle.surface.opacity(0.98)).frame(width: 5, height: 5).offset(x: 5)
            }
            .padding(.bottom, 14)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            hovering = inside
            store.holdBubble(inside)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(suggestion.byline) suggests: \(suggestion.text)")
    }

    @ViewBuilder private var footer: some View {
        switch store.suggestionStatus {
        case .idle:
            HStack(spacing: 8) {
                Button { store.answerSuggestion(yes: true) } label: {
                    Text(suggestion.yesLabel).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(SiftStyle.green, in: Capsule()).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                Button { store.answerSuggestion(yes: false) } label: {
                    Text(suggestion.notNowLabel).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(SiftStyle.raised, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if suggestion.openPath != nil || isApproval {
                    Button { store.openBubble() } label: {
                        Text("Open").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
                    }
                    .buttonStyle(.plain).help("See it in Companion first")
                }
            }
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("On it…").font(.system(size: 12)).foregroundStyle(SiftStyle.secondary)
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                .foregroundStyle(SiftStyle.green).lineLimit(2)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
                    .foregroundStyle(.orange).lineLimit(3)
                Button { store.openBubble() } label: {
                    Text("Open it instead").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var isApproval: Bool {
        if case .approve = suggestion.yes { return true }
        return false
    }
}
