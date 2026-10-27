import SwiftUI

/// Draws the cables between the orchestrator and its nodes: soft curves that sag a
/// little like real cables, lit in the host accent with particles while data moves.
@MainActor
enum CableRenderer {
    static let base = Color.white.opacity(0.13)
    /// Particles per lit cable and laps per second.
    static let particles = 3
    static let speed = 0.75

    static func screen(_ p: CGPoint, cam: Camera, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + cam.pan.width + p.x * cam.zoom,
                y: size.height / 2 + cam.pan.height + p.y * cam.zoom)
    }

    static func draw(_ ctx: inout GraphicsContext, frame f: SceneFrame, size: CGSize, accents: [String: Color]) {
        let cam = f.camera
        let center = screen(.zero, cam: cam, size: size)
        let orchSize = scaled(OrchMetrics.orchestrator, cam.zoom)
        let t = f.now.timeIntervalSinceReferenceDate
        let width = max(0.8, 1.2 * min(cam.zoom, 1.4))

        for v in f.nodes {
            let p = screen(v.position, cam: cam, size: size)
            let nodeSize = scaled(OrchMetrics.card, cam.zoom * v.scale)
            guard let c = cable(from: center, orchSize, to: p, nodeSize) else { continue }
            let path = c.path
            let fade = v.leaving ? v.opacity : min(1, v.opacity * 1.6)
            ctx.stroke(path, with: .color(base.opacity(Double(fade))), lineWidth: width)

            guard v.lit > 0, !v.leaving else { continue }
            let accent = accents[v.node.hostId] ?? Palette.muted
            let lit = Double(v.lit * v.opacity)
            ctx.stroke(path, with: .color(accent.opacity(0.14 * lit)), lineWidth: width * 4.5)
            ctx.stroke(path, with: .color(accent.opacity(0.75 * lit)), lineWidth: width * 1.2)
            let r = max(1.6, 2.3 * min(cam.zoom, 1.3))
            let toNode = v.node.flow != .toOrchestrator
            for k in 0..<particles {
                var u = (t * speed + Double(k) / Double(particles)).truncatingRemainder(dividingBy: 1)
                if !toNode { u = 1 - u }
                let q = c.point(at: CGFloat(u))
                // Fade in and out at the ends so particles don't pop.
                let edge = min(u, 1 - u) * 6
                let a = lit * min(1, edge)
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(accent.opacity(a)))
            }
        }

        if let relay = f.relay {
            let fromID = relay.from
            let from: CGPoint
            let fromSize: CGSize
            if fromID == AgentGraph.orchestratorID {
                from = center
                fromSize = orchSize
            } else if let v = f.nodes.first(where: { $0.id == fromID }) {
                from = screen(v.position, cam: cam, size: size)
                fromSize = scaled(OrchMetrics.card, cam.zoom * v.scale)
            } else {
                return
            }
            let hostId = fromID == AgentGraph.orchestratorID ? nil : f.nodes.first { $0.id == fromID }?.node.hostId
            let accent = hostId.flatMap { accents[$0] } ?? Palette.text
            let to = screen(relay.to, cam: cam, size: size)
            if let c = cable(from: from, fromSize, to: to, .zero) {
                ctx.stroke(c.path, with: .color(accent.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
                ctx.fill(Path(ellipseIn: CGRect(x: to.x - 3.5, y: to.y - 3.5, width: 7, height: 7)),
                         with: .color(accent))
            }
        }
    }

    private static func scaled(_ s: CGSize, _ k: CGFloat) -> CGSize { CGSize(width: s.width * k, height: s.height * k) }

    struct Cable {
        var a: CGPoint
        var control: CGPoint
        var b: CGPoint

        var path: Path {
            var p = Path()
            p.move(to: a)
            p.addQuadCurve(to: b, control: control)
            return p
        }

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
        }
    }

    /// Cable between the edges of two boxes, its middle dropped by gravity. Mostly
    /// horizontal cables sag the most; vertical ones hang almost straight.
    static func cable(from a: CGPoint, _ sa: CGSize, to b: CGPoint, _ sb: CGSize) -> Cable? {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = hypot(dx, dy)
        guard d > 1 else { return nil }
        let dir = CGVector(dx: dx / d, dy: dy / d)
        let ea = ForceLayout.edge(sa, dir), eb = ForceLayout.edge(sb, dir)
        guard ea + eb < d - 2 else { return nil }
        let start = CGPoint(x: a.x + dir.dx * ea, y: a.y + dir.dy * ea)
        let end = CGPoint(x: b.x - dir.dx * eb, y: b.y - dir.dy * eb)
        let len = d - ea - eb
        let sag = min(56, len * 0.22) * abs(dir.dx)
        let control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + sag)
        return Cable(a: start, control: control, b: end)
    }
}
