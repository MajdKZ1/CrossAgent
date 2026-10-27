import Foundation
import SwiftUI

/// Sizes shared by the canvas, the cards and the layout.
enum OrchMetrics {
    static let card = CGSize(width: 172, height: 52)
    static let orchestrator = CGSize(width: 236, height: 70)
    /// Room above a card for its name, and above the orchestrator for the mascot.
    static let label: CGFloat = 20
    static let mascot: CGFloat = 40
    /// Extra room around a card's hosting view for the relay handle and the zzz.
    static let margin = CGSize(width: 14, height: 30)
    static let finishedScale: CGFloat = 0.72
    static let finishedOpacity: CGFloat = 0.45
    /// How long a done node shows its check mark before it shrinks or leaves.
    static let doneHold: TimeInterval = 4
    /// How long a cable stays lit after data moved on it.
    static let flowGlow: TimeInterval = 1.5
    static let spawnDuration: TimeInterval = 0.9
    static let leaveDuration: TimeInterval = 0.55
    static let styleDuration: TimeInterval = 0.4
    static let zoomRange: ClosedRange<CGFloat> = 0.35...2.5

    static var footprint: CGSize { CGSize(width: card.width, height: card.height + 2 * label) }
    static var finishedFootprint: CGSize {
        CGSize(width: footprint.width * finishedScale, height: footprint.height * finishedScale)
    }
    static var orchestratorFootprint: CGSize {
        CGSize(width: orchestrator.width, height: orchestrator.height + 2 * mascot)
    }
}

struct Camera: Equatable {
    var pan: CGSize = .zero
    var zoom: CGFloat = 1
}

enum NodeStyle: Equatable {
    case live
    /// Done, still showing its check mark.
    case done
    /// Done a while ago, kept small and faded until the user clears it.
    case finished
}

/// One node as drawn this frame. Positions are canvas coordinates, orchestrator at (0,0).
struct NodeVisual: Identifiable {
    var id: String
    var node: AgentNode
    var position: CGPoint
    var scale: CGFloat
    var opacity: CGFloat
    var style: NodeStyle
    var leaving: Bool
}

struct SceneFrame {
    var camera: Camera
    var nodes: [NodeVisual]
    /// True while something still moves and another frame is needed.
    var busy: Bool
}

/// Data started moving on a node's cable at `at`.
struct FlowFlash {
    var id: String
    var flow: CableFlow
    var at: Date
}

/// Everything that moves on the orchestrator canvas: the layout, spawn and leave
/// animations and the camera. The stage asks for a frame on each display refresh
/// while `busy`, and not at all otherwise. Cable glow is not in here: the stage hands
/// it to Core Animation, so data flowing on a still graph costs no frames.
@MainActor
final class OrchestratorScene {
    var camera = Camera()
    /// Called when something starts moving and frames are needed again.
    var onWake: (() -> Void)?

    private struct Leave {
        var at: Date
        var from: CGPoint
        var scale: CGFloat
        var opacity: CGFloat
    }

    private struct StyleFade {
        var at: Date
        var scale: CGFloat
        var opacity: CGFloat
    }

    private struct Item {
        var node: AgentNode
        var bornAt: Date?
        var style: NodeStyle = .live
        var fade: StyleFade?
        var leave: Leave?
    }

    private var items: [String: Item] = [:]
    private var finishedIDs: Set<String> = []
    private var layout = ForceLayout(center: OrchMetrics.orchestratorFootprint)
    private var seeded = false
    private var lastTick: Date?
    /// When the layout last had a reason to move. It freezes a while after that, so a
    /// slow creep can never keep the canvas awake.
    private var layoutKick = Date()
    private var wakeItem: DispatchWorkItem?
    private var cameraAnim: (from: Camera, to: Camera, at: Date)?
    private var seenFlow: [String: Date] = [:]
    /// The positions binding as last seen, and what we wrote into it ourselves. An
    /// entry that matches neither came from outside.
    private var known: [String: CGPoint] = [:]
    private var written: [String: CGPoint] = [:]
    private var flashes: [FlowFlash] = []

    private(set) var dragging: String?
    private(set) var lastFrame: [NodeVisual] = []

    // MARK: - Graph in

    /// Brings the scene in line with the graph. New nodes spawn from the orchestrator,
    /// removed ones shrink back into it. Only wakes the frame loop when something has
    /// to move; plain data changes just redraw the cards.
    func sync(nodes: [String: AgentNode], finished: [String], positions: [String: CGPoint]) {
        let now = Date()
        var moved = false
        finishedIDs = Set(finished)
        // Oldest first, so new nodes take the free slots in the order they spawned.
        let incoming = nodes.values.filter { $0.kind != .orchestrator }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        for node in incoming {
            if var item = items[node.id] {
                if item.leave != nil {
                    // Came back before it was gone: put it back where it is now.
                    item.leave = nil
                    layout.add(id: node.id, size: OrchMetrics.footprint, pinnedAt: positions[node.id])
                    moved = true
                }
                item.node = node
                items[node.id] = item
                if let p = positions[node.id], p != known[node.id], p != written[node.id], dragging != node.id {
                    // Moved from outside (not a position we wrote ourselves): pin it there.
                    layout.pin(node.id, at: p)
                    moved = true
                }
            } else {
                // A node with a saved spot goes straight there and stays, so a reopened
                // canvas looks the way it was left. New ones spawn from the orchestrator.
                let saved = positions[node.id]
                items[node.id] = Item(node: node, bornAt: seeded && saved == nil ? now : nil)
                layout.add(id: node.id, size: OrchMetrics.footprint, pinnedAt: saved)
                moved = true
            }
            if node.flow != .none, let at = node.flowAt, at != seenFlow[node.id] {
                seenFlow[node.id] = at
                if now.timeIntervalSince(at) < OrchMetrics.flowGlow {
                    flashes.append(FlowFlash(id: node.id, flow: node.flow, at: at))
                }
            }
        }
        for (id, item) in items where nodes[id] == nil && item.leave == nil {
            startLeaving(id, now: now)
            seenFlow[id] = nil
            moved = true
        }
        known = positions
        if !seeded {
            // Nodes that were already there when the canvas opened skip their entrance.
            seeded = true
            for (id, item) in items where item.leave == nil {
                guard let style = targetStyle(item.node, now: now) else {
                    items[id] = nil
                    layout.remove(id)
                    continue
                }
                items[id]?.style = style
                if style == .finished { layout.setSize(id, OrchMetrics.finishedFootprint) }
            }
        }
        if updateStyles(now) { moved = true }
        scheduleStyleWake(now)
        if moved {
            layoutKick = now
            wake()
        }
    }

    /// Cable flashes since the last call, for the stage to animate.
    func takeFlashes() -> [FlowFlash] {
        defer { flashes = [] }
        return flashes
    }

    private func targetStyle(_ node: AgentNode, now: Date) -> NodeStyle? {
        guard node.state == .done else { return .live }
        guard let f = node.finishedAt, now.timeIntervalSince(f) >= OrchMetrics.doneHold else { return .done }
        return finishedIDs.contains(node.id) ? .finished : nil
    }

    /// Moves done nodes on to their small faded look, or sends them home. Returns true
    /// if anything changed.
    @discardableResult
    private func updateStyles(_ now: Date) -> Bool {
        var changed = false
        for (id, item) in items where item.leave == nil {
            guard let style = targetStyle(item.node, now: now) else {
                startLeaving(id, now: now)
                changed = true
                continue
            }
            guard style != item.style else { continue }
            let (s, o) = styleLook(item.style)
            items[id]?.fade = StyleFade(at: now, scale: s, opacity: o)
            items[id]?.style = style
            layout.setSize(id, style == .finished ? OrchMetrics.finishedFootprint : OrchMetrics.footprint)
            layoutKick = now
            changed = true
        }
        return changed
    }

    /// The canvas sleeps between events, so wake it when a done node is due to change.
    private func scheduleStyleWake(_ now: Date) {
        wakeItem?.cancel()
        let due = items.values.compactMap { item -> Date? in
            guard item.leave == nil, item.node.state == .done, let f = item.node.finishedAt else { return nil }
            let at = f.addingTimeInterval(OrchMetrics.doneHold)
            return at > now ? at : nil
        }.min()
        guard let due else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Date()
            if self.updateStyles(now) { self.wake() }
            self.scheduleStyleWake(now)
        }
        wakeItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + due.timeIntervalSince(now) + 0.02, execute: work)
    }

    private func startLeaving(_ id: String, now: Date) {
        guard var item = items[id], item.leave == nil else { return }
        let v = lastFrame.first { $0.id == id }
        let p = v?.position ?? layout.body(id)?.position ?? .zero
        let look = styleLook(item.style)
        item.leave = Leave(at: now, from: p, scale: v?.scale ?? look.0, opacity: v?.opacity ?? look.1)
        items[id] = item
        layout.remove(id)
        layoutKick = now
        if dragging == id { dragging = nil }
    }

    private func styleLook(_ style: NodeStyle) -> (CGFloat, CGFloat) {
        style == .finished ? (OrchMetrics.finishedScale, OrchMetrics.finishedOpacity) : (1, 1)
    }

    // MARK: - Frames

    func wake() {
        lastTick = nil
        onWake?()
    }

    /// Steps the layout and builds the frame. `step` is false for a redraw that should
    /// not advance the simulation (a pan while everything rests).
    func frame(now: Date, step: Bool = true) -> SceneFrame {
        var layoutMoving = false
        if step {
            let dt = lastTick.map { CGFloat(now.timeIntervalSince($0)) } ?? 1.0 / 60
            lastTick = now
            layoutMoving = now.timeIntervalSince(layoutKick) < 8 && layout.step(dt)
            if updateStyles(now) { scheduleStyleWake(now) }
        }

        var animating = false
        var visuals: [NodeVisual] = []
        visuals.reserveCapacity(items.count)

        for (id, item) in items {
            if let leave = item.leave {
                let t = now.timeIntervalSince(leave.at) / OrchMetrics.leaveDuration
                if t >= 1 { items[id] = nil; continue }
                animating = true
                let e = Ease.inOut(CGFloat(max(0, t)))
                visuals.append(NodeVisual(id: id, node: item.node,
                                          position: CGPoint(x: leave.from.x * (1 - e), y: leave.from.y * (1 - e)),
                                          scale: leave.scale + (0.2 - leave.scale) * e,
                                          opacity: leave.opacity * (1 - e), style: item.style, leaving: true))
                continue
            }
            guard let body = layout.body(id) else { continue }
            var p = body.position
            var (scale, opacity) = styleLook(item.style)
            if let fade = item.fade {
                let t = CGFloat(now.timeIntervalSince(fade.at) / OrchMetrics.styleDuration)
                if t >= 1 {
                    items[id]?.fade = nil
                } else {
                    animating = true
                    let e = Ease.out(max(0, t))
                    scale = fade.scale + (scale - fade.scale) * e
                    opacity = fade.opacity + (opacity - fade.opacity) * e
                }
            }
            if let born = item.bornAt {
                let t = CGFloat(now.timeIntervalSince(born) / OrchMetrics.spawnDuration)
                if t >= 1 {
                    items[id]?.bornAt = nil
                } else {
                    animating = true
                    let t = max(0, t)
                    let s = Ease.spring(t)
                    p = CGPoint(x: p.x * s, y: p.y * s)
                    scale *= 0.3 + 0.7 * Ease.out(min(1, t * 1.4))
                    opacity *= min(1, t * 4)
                }
            }
            visuals.append(NodeVisual(id: id, node: item.node, position: p, scale: scale, opacity: opacity,
                                      style: item.style, leaving: false))
        }

        // Faded finished nodes underneath, then oldest to newest.
        visuals.sort {
            let a = $0.style == .finished || $0.leaving, b = $1.style == .finished || $1.leaving
            if a != b { return a }
            return $0.node.startedAt < $1.node.startedAt
        }
        lastFrame = visuals

        if let anim = cameraAnim {
            let t = CGFloat(now.timeIntervalSince(anim.at) / 0.3)
            if t >= 1 {
                cameraAnim = nil
                camera = anim.to
            } else {
                animating = true
                let e = Ease.out(max(0, t))
                camera = Camera(pan: CGSize(width: anim.from.pan.width + (anim.to.pan.width - anim.from.pan.width) * e,
                                            height: anim.from.pan.height + (anim.to.pan.height - anim.from.pan.height) * e),
                                zoom: anim.from.zoom + (anim.to.zoom - anim.from.zoom) * e)
            }
        }

        return SceneFrame(camera: camera, nodes: visuals, busy: layoutMoving || animating || dragging != nil)
    }

    /// Jumps every animation to its end and lets the layout come to rest, for when no
    /// frames can run (window covered or hidden). A card left half way into its
    /// entrance would sit invisible on the orchestrator and take no clicks.
    func finishNow() {
        for (id, item) in items {
            if item.leave != nil {
                items[id] = nil
            } else {
                items[id]?.bornAt = nil
                items[id]?.fade = nil
            }
        }
        if let anim = cameraAnim {
            camera = anim.to
            cameraAnim = nil
        }
        for _ in 0..<900 where layout.step(1.0 / 60) {}
        lastTick = nil
    }

    // MARK: - Interaction

    /// Topmost node whose card contains `p` (canvas coordinates).
    func node(at p: CGPoint) -> String? {
        for v in lastFrame.reversed() where !v.leaving {
            let w = OrchMetrics.card.width * v.scale / 2, h = OrchMetrics.card.height * v.scale / 2
            if abs(p.x - v.position.x) <= w, abs(p.y - v.position.y) <= h { return v.id }
        }
        let o = OrchMetrics.orchestrator
        if abs(p.x) <= o.width / 2, abs(p.y) <= o.height / 2 { return AgentGraph.orchestratorID }
        return nil
    }

    /// Where every node on the canvas is now (not those on their way out), for saving.
    /// Comes from the layout itself, so it is right even if no frame has drawn yet.
    func currentPositions() -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        for (id, item) in items where item.leave == nil {
            if let b = layout.body(id) { out[id] = b.position }
        }
        return out
    }

    /// Positions the app now holds because we wrote them.
    func noteWritten(_ positions: [String: CGPoint]) {
        written.merge(positions) { _, new in new }
    }

    func position(of id: String) -> CGPoint? {
        if id == AgentGraph.orchestratorID { return .zero }
        return lastFrame.first { $0.id == id }?.position
    }

    func drag(_ id: String, to p: CGPoint) {
        guard items[id]?.leave == nil else { return }
        let start = dragging == nil
        dragging = id
        layout.pin(id, at: p)
        layoutKick = Date()
        if start { wake() }
    }

    func endDrag() {
        dragging = nil
    }

    func recenter() {
        cameraAnim = (camera, Camera(), Date())
        wake()
    }

    /// Zooms by `factor` keeping the point under `anchor` (view coordinates) still.
    func zoom(by factor: CGFloat, anchor: CGPoint, viewSize: CGSize) {
        cameraAnim = nil
        let z = min(max(camera.zoom * factor, OrchMetrics.zoomRange.lowerBound), OrchMetrics.zoomRange.upperBound)
        let k = z / camera.zoom
        let ax = anchor.x - viewSize.width / 2, ay = anchor.y - viewSize.height / 2
        camera = Camera(pan: CGSize(width: ax - (ax - camera.pan.width) * k, height: ay - (ay - camera.pan.height) * k),
                        zoom: z)
    }

    func pan(by d: CGSize) {
        cameraAnim = nil
        camera.pan.width += d.width
        camera.pan.height += d.height
    }
}

enum Ease {
    static func out(_ t: CGFloat) -> CGFloat { 1 - pow(1 - min(max(t, 0), 1), 3) }
    static func inOut(_ t: CGFloat) -> CGFloat {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    /// Eases out past the target by a few percent and settles, like a soft spring.
    static func spring(_ t: CGFloat) -> CGFloat {
        let t = min(max(t, 0), 1)
        return t >= 1 ? 1 : 1 - exp(-6 * t) * cos(7 * t)
    }
}
