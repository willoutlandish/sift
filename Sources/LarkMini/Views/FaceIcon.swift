import SwiftUI
import AppKit

/// Watches the pointer so the face's eyes can follow it. Driven by pointer-move events,
/// not a timer: a resting pointer, an expanded panel or Reduce Motion costs no wakeups.
@MainActor
final class GazeTracker: ObservableObject {
    static let shared = GazeTracker()
    @Published private(set) var offset: CGSize = .zero
    @Published private(set) var proximity: Double = 0
    var active = true

    private var monitors: [Any] = []
    private var lastUpdate = Date.distantPast

    func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
            MainActor.assumeIsolated { GazeTracker.shared.update() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            MainActor.assumeIsolated { GazeTracker.shared.update() }
            return event
        }) { monitors.append(local) }
    }

    private func update() {
        // At most 30 updates a second while the pointer moves.
        guard active, Date().timeIntervalSince(lastUpdate) > 0.033,
              let frame = PanelBridge.shared.panel?.frame else { return }
        lastUpdate = Date()
        let mouse = NSEvent.mouseLocation
        let look = Self.look(dx: mouse.x - frame.midX, dy: mouse.y - frame.midY)
        if abs(look.proximity - proximity) > 0.02 { proximity = look.proximity }
        let target = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .zero : look.offset
        if abs(target.width - offset.width) > 0.06 || abs(target.height - offset.height) > 0.06 {
            offset = target
        }
    }

    /// Eye offset toward the pointer (screen coordinates, y up) and hover closeness 0...1.
    nonisolated static func look(dx: CGFloat, dy: CGFloat) -> (offset: CGSize, proximity: Double) {
        let distance = max(1, (dx * dx + dy * dy).squareRoot())
        let reach: CGFloat = 2.8
        let strength = min(1, distance / 180)
        return (CGSize(width: dx / distance * reach * strength, height: -dy / distance * reach * strength),
                max(0, min(1, 1 - Double(distance - 22) / 68)))
    }
}

enum OllieArt {
    static func duck() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "OllieDuck", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct FaceIcon: View {
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image = OllieArt.duck() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    Circle().fill(Color(red: 0.85, green: 0.95, blue: 0.05))
                    Circle().strokeBorder(.black.opacity(0.8), lineWidth: max(1, size * 0.05))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
