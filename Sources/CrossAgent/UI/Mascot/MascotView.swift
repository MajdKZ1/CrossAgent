import AppKit
import SwiftUI

/// Patch, the CrossAgent mascot. Sits on the orchestrator node and reacts to the graph.
/// Hidden with the `mascotHidden` default.
struct MascotView: View {
    @ObservedObject var graph: AgentGraph
    var scale: CGFloat = 2

    @AppStorage("mascotHidden") private var hidden = false

    var body: some View {
        if !hidden {
            MascotSprite(source: .graph(orchestrator: graph.orchestrator, others: graph.others), scale: scale)
        }
    }
}

/// Where the mood comes from: the live graph (changes over time on its own, for the
/// done celebration and falling asleep), or a fixed mood for the gallery.
enum MascotSource: Equatable {
    case graph(orchestrator: AgentNode?, others: [AgentNode])
    case fixed(MascotMood)

    func mood(at date: Date) -> MascotMood {
        switch self {
        case .graph(let o, let n): MascotMood.from(orchestrator: o, others: n, now: date)
        case .fixed(let m): m
        }
    }

    /// Animations count from here. The done celebration starts when the node finished.
    func anchor(for mood: MascotMood) -> Date {
        if mood == .done, case .graph(let o, let n) = self, let t = MascotMood.lastFinish((o.map { [$0] } ?? []) + n) {
            return t
        }
        return Date(timeIntervalSinceReferenceDate: 0)
    }

    func nextChange(after date: Date) -> Date? {
        if case .graph(let o, let n) = self { return MascotMood.nextChange(orchestrator: o, others: n, after: date) }
        return nil
    }

    /// Mood and frame to show at a moment, and when the picture next changes.
    func state(at date: Date) -> (mood: MascotMood, frame: Int, next: Date) {
        let mood = mood(at: date)
        let (i, remaining) = MascotArt.script(mood).frame(at: date.timeIntervalSince(anchor(for: mood)))
        var next = date.addingTimeInterval(remaining)
        if let change = nextChange(after: date), change < next { next = change }
        return (mood, i, next)
    }
}

/// Ticks only when the frame changes, and not at all while paused.
struct MascotSchedule: TimelineSchedule {
    var source: MascotSource
    var paused = false

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(source: source, upcoming: startDate, paused: paused, slow: mode == .lowFrequency)
    }

    struct Entries: Sequence, IteratorProtocol {
        let source: MascotSource
        var upcoming: Date?
        let paused: Bool
        let slow: Bool

        mutating func next() -> Date? {
            guard let now = upcoming else { return nil }
            if paused {
                upcoming = nil
            } else {
                var after = source.state(at: now).next
                if slow { after = Swift.max(after, now.addingTimeInterval(1)) }
                // Never stall on a zero length step.
                upcoming = Swift.max(after, now.addingTimeInterval(0.01))
            }
            return now
        }
    }
}

/// The animated sprite. Pauses when its window is hidden, minimised or covered.
struct MascotSprite: View {
    var source: MascotSource
    var scale: CGFloat = 2

    @State private var visible = true

    var body: some View {
        TimelineView(MascotSchedule(source: source, paused: !visible)) { context in
            let s = source.state(at: context.date)
            MascotCanvas(mood: s.mood, frame: s.frame, scale: scale)
        }
        .background(WindowVisibility { visible = $0 })
        .onDisappear { visible = false }
        .onAppear { visible = true }
        .accessibilityLabel("Patch, the CrossAgent mascot")
    }
}

/// One frame, drawn as crisp integer scaled pixels.
struct MascotCanvas: View {
    var mood: MascotMood
    var frame: Int
    var scale: CGFloat

    var body: some View {
        let side = CGFloat(MascotPixels.size) * scale
        let runs = MascotArt.runs(mood, frame)
        let orbs = MascotArt.orbs(mood)
        Canvas { ctx, _ in
            var paths: [UInt8: Path] = [:]
            for r in runs {
                paths[r.color, default: Path()].addRect(
                    CGRect(x: CGFloat(r.x) * scale, y: CGFloat(r.y) * scale, width: CGFloat(r.w) * scale, height: scale))
            }
            for (c, path) in paths {
                ctx.fill(path, with: .color(MascotArt.color(c, orbs: orbs)), style: FillStyle(antialiased: false))
            }
        }
        .frame(width: side, height: side)
    }
}

/// Reports whether the hosting window is on screen and not fully covered.
private struct WindowVisibility: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.onChange = onChange }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { report(false); return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            check()
        }

        private func check() {
            report(window?.occlusionState.contains(.visible) ?? false)
        }

        private func report(_ v: Bool) {
            guard v != last else { return }
            last = v
            // Not during a view update.
            DispatchQueue.main.async { [onChange] in onChange?(v) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
