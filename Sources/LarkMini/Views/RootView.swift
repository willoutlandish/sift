import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var updates = OllieUpdates.shared
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        ZStack {
            if store.isExpanded {
                ExpandedView()
                    .transition(.opacity)
            } else {
                CollapsedBubble()
            }
        }
        .disabled(updates.requiredVersion != nil)
        .sheet(isPresented: Binding(get: { updates.requiredVersion != nil && store.isExpanded }, set: { _ in })) {
            UpdateRequiredView(update: { updates.updateNow() }, companion: { store.openCompanion() })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if store.isExpanded, store.settings.showLarkPopups, store.showsLarkSurface, !store.searchOpen, !store.toasts.isEmpty {
                ToastStack()
            }
        }
        .overlay {
            if store.searchOpen && store.isExpanded {
                ChatPickerView()
                    .transition(.asymmetric(
                        insertion: reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.searchOpen)
        .modifier(ChromeIfExpanded(expanded: store.isExpanded))
        .environment(\.siftReduceMotion, reduceMotion)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .environment(\.colorScheme, .dark)
        .environment(\.larkAccent, store.accentColor)
        .tint(store.accentColor)
        .onChange(of: store.settings.panelWidth) {
            NotificationCenter.default.post(name: .panelSettingsChanged, object: nil)
        }
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            NotificationCenter.default.post(name: .panelContentHeightChanged, object: height)
        }
    }
}

struct CollapsedBubble: View {
    @EnvironmentObject var store: Store
    @Environment(\.siftReduceMotion) private var reduceMotion
    @ObservedObject private var gaze = GazeTracker.shared
    @ObservedObject private var approvals = CompanionApprovalsMonitor.shared

    var body: some View {
        ZStack(alignment: .trailing) {
            FaceIcon(size: 36)
                .background {
                    if store.needsYouUnseen { AttentionPulse(size: 44) }
                }
                .background(
                    Circle()
                        .fill(
                            RadialGradient(stops: [
                                .init(color: Color(red: 0.86, green: 0.97, blue: 0.10).opacity(0.62), location: 0.00),
                                .init(color: Color(red: 0.90, green: 0.99, blue: 0.18).opacity(0.50), location: 0.60),
                                .init(color: Color(red: 0.94, green: 1.00, blue: 0.34).opacity(0.22), location: 0.80),
                                .init(color: Color(red: 0.97, green: 1.00, blue: 0.52).opacity(0.06), location: 0.93),
                                .init(color: Color(red: 1.00, green: 1.00, blue: 0.62).opacity(0.00), location: 1.00)
                            ], center: .center, startRadius: 0, endRadius: 30)
                        )
                        .frame(width: 60, height: 60)
                        .opacity(gaze.proximity)
                )
                .overlay(alignment: .topTrailing) {
                    if store.needsYouUnseen {
                        EmptyView()
                    } else if store.controlAttention != nil {
                        UnreadDot(size: 7)
                            .padding(2).background(SiftStyle.rail, in: Circle())
                            .offset(x: 2, y: -2)
                    } else if approvals.approvalBadge > 0 {
                        Text("\(approvals.approvalBadge)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.23)))
                            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 1))
                            .offset(x: 4, y: -4)
                    }
                }
                .padding(.trailing, 16)
                .scaleEffect(reduceMotion ? 1 : 1 + 0.05 * gaze.proximity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .help(store.attentionSummary.map { "Control · " + $0 + " · Click to open" } ?? "Open Ollie (⌥Space)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open Ollie")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { NotificationCenter.default.post(name: .expandPanel, object: nil) }
    }
}

private struct ChromeIfExpanded: ViewModifier {
    let expanded: Bool
    func body(content: Content) -> some View {
        if expanded {
            content.panelChrome()
        } else {
            content
        }
    }
}

struct ExpandedView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if isSignedIn || store.controlSeat != nil || store.companionConfigured {
                ShellView()
            } else if store.showingSettings {
                SettingsView()
            } else {
                SignInView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isSignedIn: Bool {
        if case .signedIn = store.auth { return true }
        return false
    }
}

extension Notification.Name {
    static let panelDragEnded = Notification.Name("Ollie.panelDragEnded")
    static let panelSettingsChanged = Notification.Name("Ollie.panelSettingsChanged")
    static let expandPanel = Notification.Name("Ollie.expandPanel")
    static let collapsePanel = Notification.Name("Ollie.collapsePanel")
    static let panelContentHeightChanged = Notification.Name("Ollie.panelContentHeightChanged")
}
