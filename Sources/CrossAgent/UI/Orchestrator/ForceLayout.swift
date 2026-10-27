import CoreGraphics

/// Light force layout for the orchestrator canvas. The orchestrator sits fixed at
/// (0,0); every other node hangs off it on a spring, pushes its neighbours away and
/// never overlaps them. Pure value type so it can be stepped and tested anywhere.
struct ForceLayout {
    struct Body: Equatable {
        var id: String
        var position: CGPoint
        var velocity: CGVector = .zero
        /// Footprint, including the name label above the card.
        var size: CGSize
        /// Pinned bodies (dragged by the user) never move on their own.
        var pinned = false
    }

    /// Footprint of the orchestrator at the origin.
    var center: CGSize
    /// Gap between the orchestrator's edge and the edge of a node on the first ring.
    var cable: CGFloat = 64
    /// Spring toward the first ring, per second squared per point of stretch.
    var stiffness: CGFloat = 16
    /// Spreads nodes apart around the orchestrator, by angle.
    var spread: CGFloat = 320
    var spreadRange: CGFloat = 1.9
    /// Pushes cards off cables that run through them.
    var avoid: CGFloat = 120
    /// Short range push between nearby nodes, falls off with distance squared.
    var repulsion: CGFloat = 600_000
    var repulsionRange: CGFloat = 360
    /// Extra room kept between footprints.
    var padding: CGFloat = 16
    /// Fraction of velocity lost per second.
    var friction: CGFloat = 3
    /// Below this speed (points per second) a body counts as resting.
    var restSpeed: CGFloat = 6

    private(set) var bodies: [Body] = []

    init(center: CGSize) {
        self.center = center
    }

    func index(of id: String) -> Int? { bodies.firstIndex { $0.id == id } }
    func body(_ id: String) -> Body? { index(of: id).map { bodies[$0] } }

    // MARK: - Adding and removing

    /// Places a new body in the first free slot (left, right, up, down, diagonals, then
    /// the same further out), or at `pinnedAt` if the user put it somewhere before.
    @discardableResult
    mutating func add(id: String, size: CGSize, pinnedAt: CGPoint? = nil) -> CGPoint {
        if let i = index(of: id) { return bodies[i].position }
        let p = pinnedAt ?? freeSlot(for: size)
        bodies.append(Body(id: id, position: p, size: size, pinned: pinnedAt != nil))
        return p
    }

    mutating func remove(_ id: String) {
        bodies.removeAll { $0.id == id }
    }

    mutating func setSize(_ id: String, _ size: CGSize) {
        guard let i = index(of: id) else { return }
        bodies[i].size = size
    }

    /// Pins a body at `point`, or releases it when nil.
    mutating func pin(_ id: String, at point: CGPoint?) {
        guard let i = index(of: id) else { return }
        if let point {
            bodies[i].position = point
            bodies[i].velocity = .zero
            bodies[i].pinned = true
        } else {
            bodies[i].pinned = false
        }
    }

    static let directions: [CGVector] = {
        let d = CGFloat(0.5).squareRoot()
        return [CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1), CGVector(dx: 0, dy: 1),
                CGVector(dx: -d, dy: -d), CGVector(dx: d, dy: -d), CGVector(dx: -d, dy: d), CGVector(dx: d, dy: d)]
    }()

    /// Slot `n`: eight directions per ring, rings stepping outward.
    func slot(_ n: Int, size: CGSize) -> CGPoint {
        let dir = Self.directions[n % Self.directions.count]
        let ring = CGFloat(n / Self.directions.count)
        let nodeEdge = Self.edge(size, dir)
        let dist = Self.edge(center, dir) + nodeEdge + cable + ring * (2 * nodeEdge + cable)
        return CGPoint(x: dir.dx * dist, y: dir.dy * dist)
    }

    private func freeSlot(for size: CGSize) -> CGPoint {
        for n in 0..<64 {
            let p = slot(n, size: size)
            if !bodies.contains(where: { Self.overlaps(p, size, $0.position, $0.size, pad: padding) }) { return p }
        }
        return slot(bodies.count, size: size)
    }

    // MARK: - Simulation

    /// Advances the simulation by `dt` seconds. Returns true while anything still moves.
    @discardableResult
    mutating func step(_ dt: CGFloat) -> Bool {
        guard dt > 0, !bodies.isEmpty else { return false }
        let dt = min(dt, 1.0 / 30)
        let n = bodies.count
        var accel = [CGVector](repeating: .zero, count: n)

        for i in 0..<n where !bodies[i].pinned {
            let p = bodies[i].position
            let d = max(hypot(p.x, p.y), 0.001)
            let dir = CGVector(dx: p.x / d, dy: p.y / d)
            // Spring toward the first ring, which is further out sideways since cards are wide.
            let rest = Self.edge(center, dir) + Self.edge(bodies[i].size, dir) + cable
            let stretch = max(-160, min(160, d - rest))
            accel[i].dx -= dir.dx * stiffness * stretch
            accel[i].dy -= dir.dy * stiffness * stretch
        }

        // Nodes spread around the orchestrator by angle rather than by plain distance,
        // so two of them never end up on the same ray with one cable through the other.
        let angles = bodies.map { atan2($0.position.y, $0.position.x) }
        for i in 0..<n {
            for j in (i + 1)..<n {
                var gap = angles[j] - angles[i]
                if gap > .pi { gap -= 2 * .pi } else if gap < -.pi { gap += 2 * .pi }
                guard abs(gap) < spreadRange else { continue }
                // Same angle: split them in a fixed direction so the result is deterministic.
                let sign: CGFloat = gap == 0 ? 1 : (gap > 0 ? 1 : -1)
                let push = spread * (1 / max(abs(gap), 0.08) - 1 / spreadRange)
                tangential(&accel[i], bodies[i].position, -sign * push)
                tangential(&accel[j], bodies[j].position, sign * push)

                let dx = bodies[j].position.x - bodies[i].position.x
                let dy = bodies[j].position.y - bodies[i].position.y
                let d2 = dx * dx + dy * dy
                guard d2 < repulsionRange * repulsionRange else { continue }
                let d = max(d2.squareRoot(), 0.001)
                let ux = d2 < 0.0001 ? 1 : dx / d, uy = d2 < 0.0001 ? 0 : dy / d
                let f = repulsion / max(d2, 40 * 40)
                accel[i].dx -= ux * f; accel[i].dy -= uy * f
                accel[j].dx += ux * f; accel[j].dy += uy * f
            }
        }

        // A card sitting on another node's cable slides sideways off it.
        for i in 0..<n {
            let a = bodies[i].position
            let len2 = a.x * a.x + a.y * a.y
            guard len2 > 1 else { continue }
            for j in 0..<n where j != i && !bodies[j].pinned {
                let b = bodies[j].position
                let t = (b.x * a.x + b.y * a.y) / len2
                guard t > 0, t < 1 else { continue }
                let off = CGVector(dx: b.x - a.x * t, dy: b.y - a.y * t)
                let d = hypot(off.dx, off.dy)
                let dir = CGVector(dx: a.x / len2.squareRoot(), dy: a.y / len2.squareRoot())
                let clear = Self.edge(bodies[j].size, CGVector(dx: -dir.dy, dy: dir.dx)) + padding
                guard d < clear else { continue }
                // Dead on the cable: pick a side from the ids' order so it stays deterministic.
                let ux = d < 0.5 ? -dir.dy * (i < j ? 1 : -1) : off.dx / d
                let uy = d < 0.5 ? dir.dx * (i < j ? 1 : -1) : off.dy / d
                let f = avoid * (clear - d)
                accel[j].dx += ux * f; accel[j].dy += uy * f
                if !bodies[i].pinned { accel[i].dx -= ux * f * 0.5; accel[i].dy -= uy * f * 0.5 }
            }
        }

        let keep = max(0, 1 - friction * dt)
        let maxSpeed: CGFloat = 1800
        let before = bodies.map(\.position)
        for i in 0..<n where !bodies[i].pinned {
            var v = bodies[i].velocity
            v.dx = (v.dx + accel[i].dx * dt) * keep
            v.dy = (v.dy + accel[i].dy * dt) * keep
            let s = hypot(v.dx, v.dy)
            if s > maxSpeed { v.dx *= maxSpeed / s; v.dy *= maxSpeed / s }
            bodies[i].velocity = v
            bodies[i].position.x += v.dx * dt
            bodies[i].position.y += v.dy * dt
        }

        resolveCollisions()

        // Velocity is what actually happened after collisions, so a node pressed
        // against its neighbour comes to rest instead of pushing forever.
        for i in 0..<n where !bodies[i].pinned {
            bodies[i].velocity = CGVector(dx: (bodies[i].position.x - before[i].x) / dt,
                                          dy: (bodies[i].position.y - before[i].y) / dt)
        }

        return bodies.contains { !$0.pinned && hypot($0.velocity.dx, $0.velocity.dy) > restSpeed }
    }

    /// Pushes overlapping footprints apart along the shallower axis and drops the
    /// velocity that drove them together, so crowds settle instead of jittering.
    private mutating func resolveCollisions() {
        let n = bodies.count
        for _ in 0..<3 {
            for i in 0..<n where !bodies[i].pinned {
                separate(i, from: .zero, size: center)
            }
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let a = bodies[i], b = bodies[j]
                    if a.pinned && b.pinned { continue }
                    let dx = b.position.x - a.position.x, dy = b.position.y - a.position.y
                    let ox = (a.size.width + b.size.width) / 2 + padding - abs(dx)
                    let oy = (a.size.height + b.size.height) / 2 + padding - abs(dy)
                    guard ox > 0, oy > 0 else { continue }
                    let share: (CGFloat, CGFloat) = a.pinned ? (0, 1) : b.pinned ? (1, 0) : (0.5, 0.5)
                    if ox < oy {
                        let s: CGFloat = dx == 0 ? (i < j ? 1 : -1) : (dx > 0 ? 1 : -1)
                        bodies[i].position.x -= s * ox * share.0
                        bodies[j].position.x += s * ox * share.1
                        let rel = (b.velocity.dx - a.velocity.dx) * s
                        if rel < 0 {
                            bodies[i].velocity.dx += s * rel * share.0
                            bodies[j].velocity.dx -= s * rel * share.1
                        }
                    } else {
                        let s: CGFloat = dy == 0 ? (i < j ? 1 : -1) : (dy > 0 ? 1 : -1)
                        bodies[i].position.y -= s * oy * share.0
                        bodies[j].position.y += s * oy * share.1
                        let rel = (b.velocity.dy - a.velocity.dy) * s
                        if rel < 0 {
                            bodies[i].velocity.dy += s * rel * share.0
                            bodies[j].velocity.dy -= s * rel * share.1
                        }
                    }
                }
            }
        }
    }

    private mutating func separate(_ i: Int, from c: CGPoint, size: CGSize) {
        let b = bodies[i]
        let dx = b.position.x - c.x, dy = b.position.y - c.y
        let ox = (b.size.width + size.width) / 2 + padding - abs(dx)
        let oy = (b.size.height + size.height) / 2 + padding - abs(dy)
        guard ox > 0, oy > 0 else { return }
        if ox < oy {
            let s: CGFloat = dx >= 0 ? 1 : -1
            bodies[i].position.x += s * ox
            if bodies[i].velocity.dx * s < 0 { bodies[i].velocity.dx = 0 }
        } else {
            let s: CGFloat = dy >= 0 ? 1 : -1
            bodies[i].position.y += s * oy
            if bodies[i].velocity.dy * s < 0 { bodies[i].velocity.dy = 0 }
        }
    }

    /// Adds `amount` along the counterclockwise tangent at `p` (as seen with y down).
    private func tangential(_ a: inout CGVector, _ p: CGPoint, _ amount: CGFloat) {
        let d = max(hypot(p.x, p.y), 0.001)
        a.dx += -p.y / d * amount
        a.dy += p.x / d * amount
    }

    // MARK: - Geometry

    /// Distance from the center of a `size` box to its edge along unit vector `dir`.
    static func edge(_ size: CGSize, _ dir: CGVector) -> CGFloat {
        let hw = size.width / 2, hh = size.height / 2
        let tx = abs(dir.dx) < 0.0001 ? CGFloat.infinity : hw / abs(dir.dx)
        let ty = abs(dir.dy) < 0.0001 ? CGFloat.infinity : hh / abs(dir.dy)
        return min(tx, ty)
    }

    static func overlaps(_ a: CGPoint, _ sa: CGSize, _ b: CGPoint, _ sb: CGSize, pad: CGFloat) -> Bool {
        abs(a.x - b.x) < (sa.width + sb.width) / 2 + pad && abs(a.y - b.y) < (sa.height + sb.height) / 2 + pad
    }
}
