import SwiftUI

enum OllieTone: Equatable {
    case blue
    case green
    case lime
    case amber
    case red
    case muted

    var color: Color {
        switch self {
        case .blue: return OllieStyle.blue
        case .green: return OllieStyle.green
        case .lime: return OllieStyle.lime
        case .amber: return OllieStyle.amber
        case .red: return OllieStyle.red
        case .muted: return OllieStyle.muted
        }
    }
}

enum OllieStyle {
    static let bg = Color(red: 13.0 / 255, green: 16.0 / 255, blue: 23.0 / 255)
    static let rail = Color(red: 10.0 / 255, green: 12.0 / 255, blue: 18.0 / 255)
    static let card = Color(red: 21.0 / 255, green: 26.0 / 255, blue: 36.0 / 255)
    static let card2 = Color(red: 27.0 / 255, green: 33.0 / 255, blue: 48.0 / 255)
    static let border = Color(red: 38.0 / 255, green: 45.0 / 255, blue: 59.0 / 255)
    static let text = Color(red: 232.0 / 255, green: 235.0 / 255, blue: 242.0 / 255)
    static let dim = Color(red: 139.0 / 255, green: 147.0 / 255, blue: 165.0 / 255)
    static let muted = Color(red: 107.0 / 255, green: 115.0 / 255, blue: 133.0 / 255)
    static let lime = Color(red: 200.0 / 255, green: 233.0 / 255, blue: 138.0 / 255)
    static let green = Color(red: 63.0 / 255, green: 185.0 / 255, blue: 80.0 / 255)
    static let blue = Color(red: 88.0 / 255, green: 166.0 / 255, blue: 255.0 / 255)
    static let amber = Color(red: 210.0 / 255, green: 153.0 / 255, blue: 34.0 / 255)
    static let red = Color(red: 248.0 / 255, green: 81.0 / 255, blue: 73.0 / 255)

    static let cardRadius: CGFloat = 12
}

struct OllieRise: ViewModifier {
    @Environment(\.siftReduceMotion) private var reduceMotion
    let index: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)
            .onAppear {
                guard !reduceMotion else { appeared = true; return }
                withAnimation(.easeOut(duration: 0.35).delay(Double(index) * 0.05)) {
                    appeared = true
                }
            }
    }
}

extension View {
    func ollieRise(_ index: Int) -> some View { modifier(OllieRise(index: index)) }
}

struct OllieSpinner: View {
    @Environment(\.siftReduceMotion) private var reduceMotion
    var color: Color = OllieStyle.blue
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { if !reduceMotion { spinning = true } }
            .accessibilityHidden(true)
    }
}

struct OllieWorkingPill: View {
    @Environment(\.siftReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Text("WORKING")
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(OllieStyle.blue)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(OllieStyle.blue, lineWidth: 1))
            .opacity(dim ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                       value: dim)
            .onAppear { if !reduceMotion { dim = true } }
    }
}

struct OllieStem: View {
    @Environment(\.siftReduceMotion) private var reduceMotion
    @State private var flow = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Rectangle().fill(OllieStyle.border).frame(width: 2)
                if !reduceMotion {
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, OllieStyle.blue, .clear],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 2, height: max(10, geometry.size.height * 0.5))
                        .offset(y: flow ? geometry.size.height : -geometry.size.height * 0.5)
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: flow)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 2, height: 18)
        .padding(.leading, 22)
        .onAppear { if !reduceMotion { flow = true } }
        .accessibilityHidden(true)
    }
}

struct OllieSparkline: View {
    @Environment(\.siftReduceMotion) private var reduceMotion
    let marks: [CompanionRunMark]
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                Capsule()
                    .fill(color(mark))
                    .frame(maxWidth: 14, minHeight: 8, maxHeight: 8)
                    .opacity(mark == .running ? 0.55 : 0.85)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.2, anchor: .bottom)
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)
                        .delay(Double(index) * 0.02), value: appeared)
            }
        }
        .frame(height: 8)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }

    private func color(_ mark: CompanionRunMark) -> Color {
        switch mark {
        case .ok: return OllieStyle.green
        case .partial: return OllieStyle.amber
        case .failed: return OllieStyle.red
        case .running: return OllieStyle.muted
        }
    }
}

struct OllieCompanionButton: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Button { store.openCompanion(path: "/companion/app") } label: {
            HStack(spacing: 4) {
                FaceIcon(size: 16)
                Text("Companion").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(OllieStyle.lime)
            }
        }
        .buttonStyle(.plain)
        .help("Open Companion")
        .accessibilityLabel("Open Companion")
    }
}
