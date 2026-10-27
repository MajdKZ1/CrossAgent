import AppKit
import QuartzCore
import SwiftUI

/// Hosts the stage inside SwiftUI and feeds it the graph.
struct CanvasStageView: NSViewRepresentable {
    @ObservedObject var graph: AgentGraph
    var hosts: [Host]
    @Binding var positions: [String: CGPoint]
    var actions: OrchestratorActions

    func makeNSView(context: Context) -> CanvasStage { CanvasStage() }

    func updateNSView(_ stage: CanvasStage, context: Context) {
        let binding = _positions
        stage.graph = graph
        stage.hosts = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        stage.actions = actions
        stage.onPositions = { changed in binding.wrappedValue.merge(changed) { _, new in new } }
        stage.update(nodes: graph.nodes, finished: graph.finished, positions: positions)
    }

    /// The canvas fills whatever it gets. Without this SwiftUI asks AppKit for a
    /// fitting size, which builds an Auto Layout engine over every card on each update.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CanvasStage, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 600, height: 400))
    }

    static func dismantleNSView(_ stage: CanvasStage, coordinator: ()) {
        stage.stop()
    }
}

/// The orchestrator canvas in AppKit. Cards are SwiftUI views in their own hosting
/// views that only get new content when their node changes; moving them is a frame
/// change. Cables are shape layers whose glow and particles run on the render server.
/// A display link ticks only while something moves (spawn, leave, layout, drag,
/// camera), so a still canvas, even one with data flowing, costs no frames at all.
final class CanvasStage: NSView, CardEvents {
    let scene = OrchestratorScene()
    weak var graph: AgentGraph?
    var hosts: [String: Host] = [:]
    var actions = OrchestratorActions()
    /// Hands over node positions that changed, to merge into the positions binding.
    var onPositions: ([String: CGPoint]) -> Void = { _ in }

    private let cableView = LayerView()
    private let overlayView = LayerView()
    private let relayLine = CAShapeLayer()
    private var cards: [String: CardHost] = [:]
    private var mascot: MascotHost?
    private var cables: [String: CableLayers] = [:]
    private var order: [String] = []
    private var link: CADisplayLink?
    /// Stands in for the display link when measuring under other windows, where the
    /// link (rightly) stops firing.
    private var timer: Timer?
    private var visible = true
    private var renderPending = false
    private var catchUpPending = false
    private var observer: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    private var lastNodes: [String: AgentNode] = [:]
    private var lastFinished: [String] = []
    private var lastPositions: [String: CGPoint] = [:]

    private enum Drag { case none, pan(CGPoint), move(String, CGSize), relay(String) }
    private var drag = Drag.none
    /// The card gesture `drag` belongs to: node id and where the press began. A new
    /// gesture never inherits state from one that ended without telling us (SwiftUI
    /// drops onEnded when it cancels a gesture, and a mouseUp can go missing).
    private var dragSession: (id: String, start: CGPoint)?
    private var lastDragEvent = Date.distantPast
    private var relayTo: CGPoint?
    private var dropTarget: String?

    private let logFPS = ProcessInfo.processInfo.environment["CROSSAGENT_ORCH_FPS"] == "1"
    /// Dev only: keep animating under other windows, for measuring.
    private let ignoreOcclusion = ProcessInfo.processInfo.environment["CROSSAGENT_ORCH_IGNORE_OCCLUSION"] == "1"
    private var fpsFrames = 0
    private var fpsStart = CACurrentMediaTime()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(cableView)
        addSubview(overlayView)
        relayLine.fillColor = nil
        relayLine.lineWidth = 1.5
        relayLine.lineCap = .round
        relayLine.lineDashPattern = [5, 4]
        overlayView.root.addSublayer(relayLine)
        scene.onWake = { [weak self] in self?.startFrames() }
        // Cards redraw through Palette on their own; the cable layers need a nudge.
        themeObserver = NotificationCenter.default.addObserver(forName: .crossAgentThemeChanged, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for cable in self.cables.values { cable.recolor() }
                self.render(step: false)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        link?.invalidate()
        link = nil
        guard let window else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        updateVisibility()
        scene.wake()
    }

    func stop() {
        pauseFrames()
        link?.invalidate()
        link = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func updateVisibility() {
        applyVisibility(ignoreOcclusion || (window?.occlusionState.contains(.visible) ?? false))
    }

    /// The window was covered or uncovered. Internal so the demo's regression can
    /// cover it on purpose.
    func applyVisibility(_ v: Bool) {
        guard v != visible else { return }
        visible = v
        if v {
            scene.wake()
        } else {
            pauseFrames()
            catchUp()
        }
    }

    override func layout() {
        super.layout()
        cableView.frame = bounds
        overlayView.frame = bounds
        render(step: false)
    }

    // MARK: - Graph in

    func update(nodes: [String: AgentNode], finished: [String], positions: [String: CGPoint]) {
        guard nodes != lastNodes || finished != lastFinished || positions != lastPositions else { return }
        lastNodes = nodes
        lastFinished = finished
        lastPositions = positions
        scene.sync(nodes: nodes, finished: finished, positions: positions)
        // Coalesce a burst of events into one redraw, outside SwiftUI's update.
        guard !renderPending else { return }
        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.render(step: false)
        }
    }

    // MARK: - Frames

    private func startFrames() {
        guard visible else {
            catchUp()
            return
        }
        if ignoreOcclusion {
            guard timer == nil else { return }
            fpsStart = CACurrentMediaTime()
            fpsFrames = 0
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.frameTick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            return
        }
        guard let link else { return }
        if link.isPaused {
            link.isPaused = false
            fpsStart = CACurrentMediaTime()
            fpsFrames = 0
        }
    }

    @objc private func tick(_ link: CADisplayLink) { frameTick() }

    private func frameTick() {
        // A node drag whose mouseUp never came would keep frames running forever.
        if scene.dragging != nil, Date().timeIntervalSince(lastDragEvent) > 2, NSEvent.pressedMouseButtons & 1 == 0 {
            resetDrag()
            publishPositions()
        }
        let busy = render(step: true)
        if logFPS { countFrame() }
        if !busy {
            pauseFrames()
            publishPositions()
        }
    }

    /// No frames while the window is covered, so land everything in its final place
    /// now. Coalesced, since every event while covered asks for frames.
    private func catchUp() {
        guard !catchUpPending else { return }
        catchUpPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.catchUpPending = false
            guard !self.visible else { return }
            self.scene.finishNow()
            self.render(step: false)
            self.publishPositions()
        }
    }

    /// Hands every position that moved more than half a point to the app. Runs on drag
    /// end and whenever the layout comes to rest.
    private func publishPositions() {
        let current = scene.currentPositions()
        let saved = lastPositions
        let changed = current.filter { id, p in
            guard let old = saved[id] else { return true }
            return abs(old.x - p.x) > 0.5 || abs(old.y - p.y) > 0.5
        }
        guard !changed.isEmpty else { return }
        scene.noteWritten(changed)
        onPositions(changed)
    }

    private func pauseFrames() {
        let running = timer != nil || link?.isPaused == false
        link?.isPaused = true
        timer?.invalidate()
        timer = nil
        if running && logFPS { FileHandle.standardError.write(Data("orch fps paused\n".utf8)) }
    }

    private func countFrame() {
        fpsFrames += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 {
            let line = String(format: "orch fps %.0f nodes %d\n", Double(fpsFrames) / (now - fpsStart), cards.count)
            FileHandle.standardError.write(Data(line.utf8))
            fpsFrames = 0
            fpsStart = now
        }
    }

    func screen(_ p: CGPoint, _ cam: Camera) -> CGPoint {
        CGPoint(x: bounds.width / 2 + cam.pan.width + p.x * cam.zoom,
                y: bounds.height / 2 + cam.pan.height + p.y * cam.zoom)
    }

    /// A node's center in window coordinates, for automation.
    func windowPoint(of id: String) -> CGPoint? {
        guard let p = scene.position(of: id) else { return nil }
        return convert(screen(p, scene.camera), to: nil)
    }

    func canvas(_ p: CGPoint) -> CGPoint {
        let cam = scene.camera
        return CGPoint(x: (p.x - bounds.width / 2 - cam.pan.width) / cam.zoom,
                       y: (p.y - bounds.height / 2 - cam.pan.height) / cam.zoom)
    }

    private func accent(_ hostId: String) -> Color { hosts[hostId].map(Palette.accent) ?? Palette.muted }

    private func model(_ node: AgentNode, style: NodeStyle) -> NodeCardModel {
        var from: String?
        if case .relay(let id) = drag { from = id }
        let label = HostBadge.label(hosts[node.hostId], id: node.hostId)
        return NodeCardModel(node: node, hostLabel: label, accent: accent(node.hostId), style: style,
                             target: dropTarget == node.id, relaying: from == node.id)
    }

    /// Lays out every card and cable for this moment. Returns true while busy.
    @discardableResult
    private func render(step: Bool) -> Bool {
        guard bounds.width > 0, let graph else { return false }
        let f = scene.frame(now: Date(), step: step)
        let cam = f.camera
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var ids: [String] = []
        let center = screen(.zero, cam)
        let orchSize = CGSize(width: OrchMetrics.orchestrator.width * cam.zoom,
                              height: OrchMetrics.orchestrator.height * cam.zoom)
        let lineWidth = max(0.8, 1.2 * min(cam.zoom, 1.4))

        for v in f.nodes {
            ids.append(v.id)
            let card = cards[v.id] ?? makeCard(v.id, orchestrator: false)
            card.set(model(v.node, style: v.style), events: self, orchestrator: false)
            card.interactive = !v.leaving
            let p = screen(v.position, cam)
            card.place(center: p, scale: v.scale * cam.zoom, opacity: v.opacity)

            let cable = cables[v.id] ?? makeCable(v.id)
            let size = CGSize(width: OrchMetrics.card.width * cam.zoom * v.scale,
                              height: OrchMetrics.card.height * cam.zoom * v.scale)
            let fade = v.leaving ? v.opacity : min(1, v.opacity * 1.6)
            cable.update(CableGeometry.cable(from: center, orchSize, to: p, size), width: lineWidth,
                         opacity: Float(fade), accent: NSColor(accent(v.node.hostId)).cgColor)
        }

        if let orch = graph.orchestrator {
            ids.append(orch.id)
            let card = cards[orch.id] ?? makeCard(orch.id, orchestrator: true)
            card.set(model(orch, style: .live), events: self, orchestrator: true)
            card.place(center: center, scale: cam.zoom, opacity: 1)
            // The mascot sits on the card's top edge, sunk 3 pt into it.
            let m = mascot ?? makeMascot(graph)
            let top = center.y - OrchMetrics.orchestrator.height / 2 * cam.zoom
            m.place(center: CGPoint(x: center.x, y: top - (m.natural.height / 2 - 3) * cam.zoom),
                    scale: cam.zoom, opacity: 1)
        }

        let now = Date()
        for flash in scene.takeFlashes() {
            cables[flash.id]?.flash(flash.flow, age: now.timeIntervalSince(flash.at))
        }

        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
            cables[id]?.remove()
            cables[id] = nil
        }
        if ids != order {
            order = ids
            subviews = [cableView] + ids.compactMap { cards[$0] } + [mascot].compactMap { $0 } + [overlayView]
        }
        drawRelay(cam)
        CATransaction.commit()
        return f.busy
    }

    private func makeCard(_ id: String, orchestrator: Bool) -> CardHost {
        let c = CardHost(size: CardRoot.size(orchestrator: orchestrator))
        cards[id] = c
        return c
    }

    private func makeMascot(_ graph: AgentGraph) -> MascotHost {
        let m = MascotHost(graph: graph) { [weak self] id in self?.actions.expand(id) }
        mascot = m
        order = []
        return m
    }

    private func makeCable(_ id: String) -> CableLayers {
        let c = CableLayers(in: cableView.root)
        cables[id] = c
        return c
    }

    // MARK: - Relay

    private func drawRelay(_ cam: Camera) {
        guard case .relay(let from) = drag, let to = relayTo,
              let fromPos = scene.position(of: from) else {
            if relayLine.path != nil { relayLine.path = nil }
            return
        }
        let isOrch = from == AgentGraph.orchestratorID
        let scale = isOrch ? 1 : (scene.lastFrame.first { $0.id == from }?.scale ?? 1)
        let base = isOrch ? OrchMetrics.orchestrator : OrchMetrics.card
        let size = CGSize(width: base.width * scale * cam.zoom, height: base.height * scale * cam.zoom)
        let hostId = isOrch ? graph?.orchestrator?.hostId : scene.lastFrame.first { $0.id == from }?.node.hostId
        let color = hostId.map { NSColor(accent($0)) } ?? NSColor(Palette.text)
        relayLine.strokeColor = color.withAlphaComponent(0.85).cgColor
        let path = CGMutablePath()
        let end = screen(to, cam)
        if let c = CableGeometry.cable(from: screen(fromPos, cam), size, to: end, .zero) {
            path.addPath(c.path())
            path.addEllipse(in: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
        }
        relayLine.path = path
    }

    private func setRelay(from id: String, to p: CGPoint) {
        drag = .relay(id)
        relayTo = p
        let t = scene.node(at: p).flatMap { $0 == id ? nil : $0 }
        dropTarget = t
        render(step: false)
    }

    private func finishRelay() {
        if case .relay(let from) = drag, let to = dropTarget { actions.relay(from, to) }
        drag = .none
        relayTo = nil
        dropTarget = nil
        render(step: false)
    }

    // MARK: - Card events

    /// The pointer from the event being handled, so synthetic events work too; the
    /// live cursor only as a fallback.
    private var mouse: CGPoint {
        if let e = NSApp.currentEvent, e.window === window, Self.mouseTypes.contains(e.type) {
            return convert(e.locationInWindow, from: nil)
        }
        return convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
    }

    private var optionHeld: Bool {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.option)
    }

    private static let mouseTypes: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

    func cardTapped(_ id: String) { actions.expand(id) }
    func cardAnswer(_ id: String) { actions.answer(id) }

    func cardDragChanged(_ id: String, start: CGPoint) {
        let m = mouse
        if dragSession?.id != id || dragSession?.start != start {
            resetDrag()
            dragSession = (id, start)
        }
        lastDragEvent = Date()
        if case .none = drag {
            // Start from where the press began, not where the gesture kicked in, so
            // nothing lags the cursor. `start` is relative to the card, which sits
            // inside its hosting view's margin.
            let local = CGPoint(x: start.x + OrchMetrics.margin.width, y: start.y + OrchMetrics.margin.height)
            let pressed = cards[id].map { $0.convert(local, to: self) } ?? m
            if optionHeld {
                drag = .relay(id)
            } else if id == AgentGraph.orchestratorID {
                // The orchestrator stays at the center; dragging it pans.
                drag = .pan(pressed)
            } else {
                let c = canvas(pressed)
                let at = scene.position(of: id) ?? c
                drag = .move(id, CGSize(width: at.x - c.x, height: at.y - c.y))
            }
        }
        switch drag {
        case .pan(let last):
            scene.pan(by: CGSize(width: m.x - last.x, height: m.y - last.y))
            drag = .pan(m)
            render(step: false)
        case .move(let id, let grab):
            let c = canvas(m)
            scene.drag(id, to: CGPoint(x: c.x + grab.width, y: c.y + grab.height))
        case .relay(let from):
            setRelay(from: from, to: canvas(m))
        case .none:
            break
        }
    }

    /// Drops whatever an earlier gesture left behind.
    private func resetDrag() {
        if scene.dragging != nil { scene.endDrag() }
        if case .relay = drag {
            relayTo = nil
            dropTarget = nil
        }
        drag = .none
        dragSession = nil
    }

    func cardDragEnded(_ id: String) {
        defer { dragSession = nil }
        switch drag {
        case .move(let id, let grab):
            // Pin the spot under the final pointer, not the last drawn frame, which can
            // lag behind when the display link is slow or paused.
            let c = canvas(mouse)
            scene.drag(id, to: CGPoint(x: c.x + grab.width, y: c.y + grab.height))
            scene.endDrag()
            drag = .none
            publishPositions()
        case .relay:
            finishRelay()
        default:
            drag = .none
        }
    }

    func handleDragChanged(_ id: String) {
        if case .relay(let from) = drag, from == id {} else { resetDrag() }
        setRelay(from: id, to: canvas(mouse))
    }
    func handleDragEnded(_ id: String) { finishRelay() }

    // MARK: - Mouse on empty space

    override func mouseDown(with e: NSEvent) {
        // A press on empty space starts fresh, whatever an earlier gesture left behind.
        resetDrag()
        if e.clickCount == 2 {
            scene.recenter()
            return
        }
        drag = .pan(convert(e.locationInWindow, from: nil))
    }

    override func mouseDragged(with e: NSEvent) {
        guard case .pan(let last) = drag else { return }
        let m = convert(e.locationInWindow, from: nil)
        scene.pan(by: CGSize(width: m.x - last.x, height: m.y - last.y))
        drag = .pan(m)
        render(step: false)
    }

    override func mouseUp(with e: NSEvent) {
        if case .pan = drag { drag = .none }
    }

    override func scrollWheel(with e: NSEvent) {
        let scale: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        if e.modifierFlags.contains(.command) {
            scene.zoom(by: exp(e.scrollingDeltaY * scale * 0.008), anchor: convert(e.locationInWindow, from: nil),
                       viewSize: bounds.size)
        } else {
            scene.pan(by: CGSize(width: e.scrollingDeltaX * scale, height: e.scrollingDeltaY * scale))
        }
        render(step: false)
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, at: convert(e.locationInWindow, from: nil))
    }

    /// Zooms keeping `point` (view coordinates) still. Pinch lands here, and so does
    /// automation, since gesture events can't be synthesized.
    func zoom(by factor: CGFloat, at point: CGPoint) {
        scene.zoom(by: factor, anchor: point, viewSize: bounds.size)
        render(step: false)
    }

    /// Clicks reach the canvas even when its window is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Wrapper whose bounds stay at its content's natural size while its frame follows
/// the zoom and the node's own scale, so AppKit scales the hosting view inside.
class ScaledView: NSView {
    let natural: CGSize
    var interactive = true

    init(natural: CGSize) {
        self.natural = natural
        super.init(frame: CGRect(origin: .zero, size: natural))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive && alphaValue > 0.05 ? super.hitTest(point) : nil
    }

    func place(center: CGPoint, scale: CGFloat, opacity: CGFloat) {
        let px = 1 / (window?.backingScaleFactor ?? 2)
        let w = natural.width * scale, h = natural.height * scale
        // Snap to device pixels so text stays crisp on still cards.
        let x = ((center.x - w / 2) / px).rounded() * px, y = ((center.y - h / 2) / px).rounded() * px
        let f = CGRect(x: x, y: y, width: w, height: h)
        if frame.size != f.size {
            frame = f
            bounds = CGRect(origin: .zero, size: natural)
        } else if frame.origin != f.origin {
            // A plain move: no resize, so the hosting view needs no layout.
            setFrameOrigin(f.origin)
        }
        if alphaValue != opacity { alphaValue = opacity }
    }
}

/// One card. Its SwiftUI content is only replaced when the card's model changes.
final class CardHost: ScaledView {
    private let hosting: CardHostingView
    private var model: NodeCardModel?

    init(size: CGSize) {
        hosting = CardHostingView(rootView: CardRoot(model: NodeCardModel(
            node: AgentNode(id: "", name: "", kind: .subagent, hostId: "", state: .idle, activity: "",
                            startedAt: .distantPast, updatedAt: .distantPast),
            hostLabel: "", accent: .clear, style: .live, target: false, relaying: false)))
        hosting.sizingOptions = []
        super.init(natural: size)
        hosting.frame = CGRect(origin: .zero, size: size)
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ m: NodeCardModel, events: CardEvents, orchestrator: Bool) {
        guard m != model else { return }
        model = m
        hosting.rootView = CardRoot(model: m, events: events, orchestrator: orchestrator)
    }
}

/// Cards act on the first click even when their window is not key, like the canvas.
/// If a mouseUp never reached the card, SwiftUI keeps the old drag open and ignores
/// every later press on it, so the card goes dead. A press that arrives while the
/// button still looks down closes the stale gesture first.
final class CardHostingView: NSHostingView<CardRoot> {
    private var lastDown: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let stale = lastDown,
           let up = NSEvent.mouseEvent(with: .leftMouseUp, location: stale.locationInWindow,
                                       modifierFlags: stale.modifierFlags, timestamp: event.timestamp,
                                       windowNumber: stale.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: stale.clickCount, pressure: 0) {
            super.mouseUp(with: up)
        }
        lastDown = event
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        lastDown = nil
        super.mouseUp(with: event)
    }
}

/// The mascot in its own small hosting view, so its animation frames only update
/// itself and never the orchestrator card or the window around it.
final class MascotHost: ScaledView {
    /// Takes clicks: poking the mascot plays a trick, and its orbs open their agent.
    init(graph: AgentGraph, onOpenAgent: @escaping (String) -> Void) {
        let hosting = NSHostingView(rootView: MascotView(graph: graph, onOpenAgent: onOpenAgent))
        hosting.sizingOptions = []
        let fit = hosting.fittingSize
        let size = fit.width > 1 && fit.height > 1 ? fit : CGSize(width: 40, height: 40)
        super.init(natural: size)
        hosting.frame = CGRect(origin: .zero, size: size)
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Plain layer holder that never takes clicks. `root` uses top left coordinates.
final class LayerView: NSView {
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        root.isGeometryFlipped = true
        layer?.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
