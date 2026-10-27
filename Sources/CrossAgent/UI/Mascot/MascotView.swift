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
            MascotLayer(source: .graph(orchestrator: graph.orchestrator, others: graph.others), scale: scale)
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

    /// Mood and loop frame at a moment. Used for stills; live views animate on a layer.
    func state(at date: Date) -> (mood: MascotMood, frame: Int) {
        let mood = mood(at: date)
        return (mood, MascotArt.script(mood).frame(at: date.timeIntervalSince(anchor(for: mood))).index)
    }
}

/// The live sprite. Frames are pre-rendered images looped by Core Animation, so the
/// app does no work per frame: only when the mood changes.
struct MascotLayer: NSViewRepresentable {
    var source: MascotSource
    var scale: CGFloat = 2

    func makeNSView(context: Context) -> MascotLayerView { MascotLayerView() }

    func updateNSView(_ view: MascotLayerView, context: Context) {
        view.update(source: source, scale: scale)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MascotLayerView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(MascotPixels.size) * scale, height: CGFloat(MascotPixels.size) * scale)
    }
}

final class MascotLayerView: NSView {
    let sprite = CALayer()
    private var source: MascotSource?
    private var scale: CGFloat = 2
    /// What is on the layer now, so unrelated graph updates do nothing.
    private var shown: (mood: MascotMood, px: Int)?
    /// Fires once when the mood would change by time alone (done ends, error fades, sleep).
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sprite.magnificationFilter = .nearest
        sprite.minificationFilter = .nearest
        sprite.contentsGravity = .resize
        layer?.addSublayer(sprite)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Patch, the CrossAgent mascot")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func update(source: MascotSource, scale: CGFloat) {
        guard source != self.source || scale != self.scale else { return }
        self.source = source
        self.scale = scale
        refresh()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        guard let source, let window else { return }
        let now = Date()
        let mood = source.mood(at: now)
        let backing = window.backingScaleFactor
        let px = max(1, Int((scale * backing).rounded()))
        if shown?.mood != mood || shown?.px != px {
            show(mood, px: px, backing: backing, phase: now.timeIntervalSince(source.anchor(for: mood)))
        }
        if let next = source.nextChange(after: now) {
            let t = Timer(fire: next.addingTimeInterval(0.01), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func show(_ mood: MascotMood, px: Int, backing: CGFloat, phase: TimeInterval) {
        shown = (mood, px)
        let frames = MascotArt.images(mood, px: px)
        let script = MascotArt.script(mood)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.removeAnimation(forKey: "frames")
        sprite.contentsScale = backing
        sprite.contents = frames.first
        if frames.count > 1 {
            let a = CAKeyframeAnimation(keyPath: "contents")
            a.values = frames
            a.keyTimes = script.keyTimes.map { NSNumber(value: $0) }
            a.calculationMode = .discrete
            a.duration = script.total
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            // Start partway in, so loops stay in step with the anchor (the done jump
            // begins when the node finished).
            var offset = phase.truncatingRemainder(dividingBy: script.total)
            if offset < 0 { offset += script.total }
            a.beginTime = sprite.convertTime(CACurrentMediaTime(), from: nil) - offset
            sprite.add(a, forKey: "frames")
        }
        CATransaction.commit()
    }

    deinit { timer?.invalidate() }
}

/// One still frame, for the snapshot tool.
struct MascotStill: View {
    var mood: MascotMood
    var frame: Int
    var scale: CGFloat

    var body: some View {
        let side = CGFloat(MascotPixels.size) * scale
        let images = MascotArt.images(mood, px: Int(scale))
        Group {
            if frame < images.count {
                Image(decorative: images[frame], scale: 1).interpolation(.none).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
    }
}
