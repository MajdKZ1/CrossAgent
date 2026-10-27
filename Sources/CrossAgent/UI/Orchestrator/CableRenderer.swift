import AppKit
import QuartzCore

/// Cable geometry: soft curves between two boxes that sag a little like real cables.
enum CableGeometry {
    struct Cable: Equatable {
        var a: CGPoint
        var control: CGPoint
        var b: CGPoint

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
        }

        func path(reversed: Bool = false) -> CGPath {
            let p = CGMutablePath()
            p.move(to: reversed ? b : a)
            p.addQuadCurve(to: reversed ? a : b, control: control)
            return p
        }

        /// Same cable to within a quarter point, so still frames skip path updates.
        func near(_ o: Cable) -> Bool {
            func close(_ p: CGPoint, _ q: CGPoint) -> Bool { abs(p.x - q.x) < 0.25 && abs(p.y - q.y) < 0.25 }
            return close(a, o.a) && close(b, o.b) && close(control, o.control)
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

/// One node's cable as Core Animation layers. The glow and the particles run as
/// animations on the render server, so a lit cable costs the app nothing per frame.
@MainActor
final class CableLayers {
    /// Resting cable colour: the theme's border tone, a bit stronger.
    static var base: CGColor { ThemeTokens.shared.resolved.border.withAlphaComponent(0.13).cgColor }
    static let particleCount = 3
    /// Seconds per lap of a particle.
    static let lap: CFTimeInterval = 1.33

    private let line = CAShapeLayer()
    private let glow = CALayer()
    private let halo = CAShapeLayer()
    private let core = CAShapeLayer()
    private let dots: [CALayer]
    private var cable: CableGeometry.Cable?
    private var flow: CableFlow = .none
    private var glowUntil: CFTimeInterval = 0
    private var width: CGFloat = 0
    private var accent: CGColor?

    init(in parent: CALayer) {
        dots = (0..<Self.particleCount).map { _ in CALayer() }
        for l in [line, halo, core] {
            l.fillColor = nil
            l.lineCap = .round
        }
        line.strokeColor = Self.base
        glow.opacity = 0
        glow.addSublayer(halo)
        glow.addSublayer(core)
        for d in dots { glow.addSublayer(d) }
        parent.addSublayer(line)
        parent.addSublayer(glow)
    }

    /// After a theme switch. Accents come back through `update`.
    func recolor() {
        line.strokeColor = Self.base
    }

    func remove() {
        line.removeFromSuperlayer()
        glow.removeFromSuperlayer()
    }

    /// Call inside a transaction with actions disabled.
    func update(_ c: CableGeometry.Cable?, width w: CGFloat, opacity: Float, accent a: CGColor) {
        if line.opacity != opacity { line.opacity = opacity }
        if accent != a {
            accent = a
            halo.strokeColor = a.copy(alpha: 0.14)
            core.strokeColor = a.copy(alpha: 0.75)
            for d in dots { d.backgroundColor = a }
        }
        if width != w {
            width = w
            line.lineWidth = w
            halo.lineWidth = w * 4.5
            core.lineWidth = w * 1.2
            let r = max(1.6, 2.3 * min(w / 1.2, 1.3))
            for d in dots {
                d.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
                d.cornerRadius = r
            }
        }
        let changed: Bool
        switch (cable, c) {
        case let (old?, new?): changed = !old.near(new)
        case (nil, nil): changed = false
        default: changed = true
        }
        guard changed else { return }
        cable = c
        let path = c?.path()
        line.path = path
        halo.path = path
        core.path = path
        if CACurrentMediaTime() < glowUntil { runParticles() }
    }

    /// Lights the cable for the rest of its glow and sends particles along it.
    func flash(_ f: CableFlow, age: TimeInterval) {
        let remaining = OrchMetrics.flowGlow - max(0, age)
        guard remaining > 0.05, f != .none else { return }
        flow = f
        glowUntil = CACurrentMediaTime() + remaining
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1 - Float(max(0, age) / OrchMetrics.flowGlow)
        fade.toValue = 0
        fade.duration = remaining
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        glow.add(fade, forKey: "fade")
        runParticles()
    }

    private func runParticles() {
        guard let cable else { return }
        let remaining = glowUntil - CACurrentMediaTime()
        guard remaining > 0 else { return }
        let path = cable.path(reversed: flow == .toOrchestrator)
        // A shared clock keeps particles evenly spaced when the path is swapped mid run.
        let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.lap)
        for (k, d) in dots.enumerated() {
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            move.duration = Self.lap
            move.timeOffset = (phase + Self.lap * Double(k) / Double(Self.particleCount))
                .truncatingRemainder(dividingBy: Self.lap)
            move.repeatDuration = remaining
            move.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            d.add(move, forKey: "move")
        }
    }
}
