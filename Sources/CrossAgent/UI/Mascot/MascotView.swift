import AppKit
import Combine
import SwiftUI

/// Puff, the CrossAgent mascot. Sits on the orchestrator node and reacts to the graph.
/// Clicking an orb opens that agent. Hidden with the `mascotHidden` default.
struct MascotView: View {
    @ObservedObject var graph: AgentGraph
    var onOpenAgent: ((String) -> Void)?
    /// Points per design unit. 0.75 makes the body about 45 pt wide.
    var scale: CGFloat = 0.75

    @AppStorage("mascotHidden", store: AppDefaults.store) private var hidden = false

    init(graph: AgentGraph, onOpenAgent: ((String) -> Void)? = nil, scale: CGFloat = 0.75) {
        self.graph = graph
        self.onOpenAgent = onOpenAgent
        self.scale = scale
    }

    var body: some View {
        if !hidden {
            MascotLayer(source: .graph(orchestrator: graph.orchestrator, others: graph.others), scale: scale,
                        onOpenAgent: onOpenAgent)
        }
    }
}

/// Where the mood comes from: the live graph (changes over time on its own, for the
/// done celebration, the error fading and falling asleep), or a fixed mood for the gallery.
enum MascotSource: Equatable {
    case graph(orchestrator: AgentNode?, others: [AgentNode])
    case fixed(MascotMood)

    func mood(at date: Date) -> MascotMood {
        switch self {
        case .graph(let o, let n): MascotMood.from(orchestrator: o, others: n, now: date)
        case .fixed(let m): m
        }
    }

    func nextChange(after date: Date) -> Date? {
        if case .graph(let o, let n) = self { return MascotMood.nextChange(orchestrator: o, others: n, after: date) }
        return nil
    }
}

struct MascotLayer: NSViewRepresentable {
    var source: MascotSource
    var scale: CGFloat = 0.75
    var onOpenAgent: ((String) -> Void)?

    func makeNSView(context: Context) -> MascotLayerView { MascotLayerView() }

    func updateNSView(_ view: MascotLayerView, context: Context) {
        view.onOpenAgent = onOpenAgent
        view.update(source: source, scale: scale)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MascotLayerView, context: Context) -> CGSize? {
        MascotLayerView.size(scale: scale)
    }
}

/// Hosts the rig. Only does work when the mood changes, on a sparse idle gesture
/// timer, and on pointer events over it. Freezes while its window is hidden or covered.
final class MascotLayerView: NSView {
    let rig = MascotRig()
    var onOpenAgent: ((String) -> Void)?
    private var source: MascotSource?
    private var scale: CGFloat = 0.75
    /// Fires once when the mood would change by time alone (done ends, error fades, sleep).
    private var moodTimer: Timer?
    /// The next blink or glance. Only one is ever scheduled.
    private var gestureTimer: Timer?
    private var play = MascotPlay()
    private var rng = SystemRandomNumberGenerator()
    private var observers: [NSObjectProtocol] = []
    private var occlusion: NSObjectProtocol?
    private var hovering = false
    private var graphWatch: AnyCancellable?

    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: MascotGeometry.size.width * scale, height: MascotGeometry.size.height * scale)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(rig.canvas)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Puff, the CrossAgent mascot")
        #if DEBUG
        MascotDemo.views.add(self)
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: .crossAgentThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rig.recolor() }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        moodTimer?.invalidate()
        gestureTimer?.invalidate()
        (observers + [occlusion].compactMap { $0 }).forEach(NotificationCenter.default.removeObserver)
    }

    /// For AppKit hosts (no SwiftUI in between): follow a graph directly. Size the view
    /// with `MascotLayerView.size(scale:)`.
    func follow(_ graph: AgentGraph, scale: CGFloat = 0.75) {
        graphWatch = graph.$nodes.receive(on: RunLoop.main).sink { [weak self, weak graph] _ in
            guard let self, let graph else { return }
            self.update(source: .graph(orchestrator: graph.orchestrator, others: graph.others), scale: self.scale)
        }
        update(source: .graph(orchestrator: graph.orchestrator, others: graph.others), scale: scale)
    }

    func update(source: MascotSource, scale: CGFloat) {
        guard source != self.source || scale != self.scale else { return }
        let rescale = scale != self.scale
        self.source = source
        self.scale = scale
        if rescale { needsLayout = true; applyScale() }
        refresh()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let k = bounds.width / MascotGeometry.size.width
        rig.canvas.position = .zero
        rig.canvas.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusion { NotificationCenter.default.removeObserver(o) }
        occlusion = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: $0,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            }
        }
        applyScale()
        refresh()
        updateRunning()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    override func viewDidHide() { super.viewDidHide(); updateRunning() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateRunning() }

    private func applyScale() {
        rig.setScale(scale, backing: window?.backingScaleFactor ?? 2)
    }

    /// On screen and not covered: run. Otherwise freeze and drop the gesture timer.
    var isShowing: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func updateRunning() {
        let on = isShowing
        rig.setRunning(on)
        if on { scheduleGesture() } else { gestureTimer?.invalidate(); gestureTimer = nil }
    }

    private func refresh() {
        moodTimer?.invalidate()
        moodTimer = nil
        guard let source else { return }
        let now = Date()
        var mood = source.mood(at: now)
        #if DEBUG
        if let m = MascotDemo.mood { mood = m }
        #endif
        if rig.mood != mood {
            rig.set(mood, animated: window != nil)
            gestureTimer?.invalidate()
            gestureTimer = nil
            scheduleGesture()
        }
        if let next = source.nextChange(after: now) {
            let t = Timer(fire: next.addingTimeInterval(0.01), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            moodTimer = t
        }
    }

    /// Brings in a forced mood, or drops it again. See MascotDemo.
    func refreshMood() { refresh() }

    /// A trick like a click on the body: `name` picks one (spin, squish, jelly,
    /// peekaboo, ricochet), nil a random one.
    func playTrick(_ name: String? = nil) {
        if let t = MascotPlay.Trick.allCases.first(where: { "\($0)" == name }) {
            rig.play(MascotPlay.Move(tricks: [t], intensity: 1), rng: &rng)
        } else {
            rig.play(play.click(at: ProcessInfo.processInfo.systemUptime, using: &rng), rng: &rng)
        }
    }

    // MARK: Idle gestures

    private static let gestureMoods: Set<String> = ["idle", "thinking", "working", "bobbing", "juggling", "needsInput"]

    private func scheduleGesture() {
        guard gestureTimer == nil, isShowing, let mood = rig.mood, Self.gestureMoods.contains(mood.name) else { return }
        let wait = Double.random(in: 2.4...5.8, using: &rng)
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.gestureTimer = nil
                self?.gesture()
                self?.scheduleGesture()
            }
        }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        gestureTimer = t
    }

    private func gesture() {
        guard !hovering else { return rig.blink() }
        let roll = Double.random(in: 0..<1, using: &rng)
        if rig.mood == .idle, roll < 0.25, let p = pointerInDesignSpace() {
            // Peek at wherever the pointer is, without any global monitor.
            rig.glance(MascotRig.gazeOffset(toward: p, from: MascotPose.eyeLine, reach: 3.4), hold: 1.1)
        } else if rig.mood == .idle, roll < 0.55 {
            let o = CGPoint(x: CGFloat.random(in: -3.4...3.4, using: &rng), y: CGFloat.random(in: -2.6...1.6, using: &rng))
            rig.glance(o, hold: Double.random(in: 0.6...1.5, using: &rng))
        } else {
            rig.blink(double: roll > 0.85)
        }
    }

    private func pointerInDesignSpace() -> CGPoint? {
        guard let window else { return nil }
        let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return designPoint(p)
    }

    /// View point to design units (y down).
    private func designPoint(_ p: NSPoint) -> CGPoint {
        let k = bounds.width / MascotGeometry.size.width
        guard k > 0 else { return .zero }
        let y = isFlipped ? p.y : bounds.height - p.y
        return CGPoint(x: p.x / k, y: y / k)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; follow(event) }
    override func mouseMoved(with event: NSEvent) { follow(event) }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        rig.look(toward: nil)
        NSCursor.arrow.set()
    }

    private func follow(_ event: NSEvent) {
        guard rig.mood != .sleeping, rig.mood != .done else { return }
        let p = designPoint(convert(event.locationInWindow, from: nil))
        rig.look(toward: p)
        if case .orb = rig.hit(p) { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let p = designPoint(convert(point, from: superview))
        return rig.hit(p) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        switch rig.hit(designPoint(convert(event.locationInWindow, from: nil))) {
        case .orb(let id):
            onOpenAgent?(id)
        case .body:
            let move = play.click(at: event.timestamp, using: &rng)
            rig.play(move, rng: &rng)
        case nil:
            super.mouseDown(with: event)
        }
    }
}

extension MascotMood {
    var name: String {
        switch self {
        case .idle: "idle"
        case .thinking: "thinking"
        case .working: "working"
        case .bobbing: "bobbing"
        case .juggling: "juggling"
        case .needsInput: "needsInput"
        case .done: "done"
        case .error: "error"
        case .sleeping: "sleeping"
        }
    }
}
