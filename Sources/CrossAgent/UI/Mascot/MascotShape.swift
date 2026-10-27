import CoreGraphics
import Foundation

/// Body outlines Puff can morph between. Every one is built from the same number of
/// cubic segments, so Core Animation can tween the path point for point.
enum MascotBodyShape: CaseIterable, Equatable {
    /// The usual look: a chunky soft squircle, a touch wider at the bottom.
    case squircle
    /// Calm and round, for sleeping.
    case round
    /// Fluffy, for thinking.
    case cloud
    /// A softer cloud, for busy moods.
    case puffy
}

/// Puff lives in a fixed design space (y down) and gets scaled to the view.
enum MascotGeometry {
    static let size = CGSize(width: 100, height: 90)
    static let center = CGPoint(x: 50, y: 61)
    static let half = CGSize(width: 30, height: 27.5)
    /// Anchor points around every outline. A multiple of 8 and 6, so cloud bumps land on anchors.
    static let anchors = 48

    static var bottom: CGFloat { center.y + half.height }
    static var top: CGFloat { center.y - half.height }

    static func bodyPath(_ shape: MascotBodyShape) -> CGPath {
        smoothPath(through: bodyPoints(shape))
    }

    static func bodyPoints(_ shape: MascotBodyShape) -> [CGPoint] {
        switch shape {
        case .squircle:
            return squirclePoints
        case .round:
            let r = (half.width + half.height) / 2 * 0.97
            return outline { CGPoint(x: center.x + r * 1.03 * cos($0), y: center.y + 1 + r * 0.97 * sin($0)) }
        case .cloud:
            return puffed(outline(superellipse(top: 2.15, bottom: 2.6, half: half.scaled(0.95))), bumps: 8, height: 5.6)
        case .puffy:
            return puffed(outline(superellipse(top: 2.2, bottom: 2.7, half: half.scaled(0.98))), bumps: 8, height: 2.2)
        }
    }

    /// Rounder on top, flatter at the bottom, like it's sitting on something.
    static let squirclePoints = outline(superellipse(top: 2.25, bottom: 2.75, half: half))

    /// Superellipse by angle, a little wider toward the bottom. Ends on the same bottom line for any size.
    static func superellipse(top: CGFloat, bottom: CGFloat, half h: CGSize) -> (CGFloat) -> CGPoint {
        let cy = Self.bottom - h.height
        return { t in
            let c = cos(t), s = sin(t)
            let n = s > 0 ? bottom : top
            let r = 1 / pow(pow(abs(c) / h.width, n) + pow(abs(s) / h.height, n), 1 / n)
            let y = r * s
            return CGPoint(x: center.x + r * c * (1 + 0.045 * y / h.height), y: cy + y)
        }
    }

    /// A closed curve (by angle, starting at the top, clockwise) resampled to `anchors`
    /// points evenly spaced along its length. Same start and spacing for every shape,
    /// so morphs line up and puffs come out the same size.
    static func outline(_ curve: (CGFloat) -> CGPoint) -> [CGPoint] {
        let dense = 960
        let pts = (0...dense).map { curve(-.pi / 2 + 2 * .pi * CGFloat($0) / CGFloat(dense)) }
        var len: [CGFloat] = [0]
        for i in 1...dense { len.append(len[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = len[dense]
        var out: [CGPoint] = []
        var j = 0
        for k in 0..<anchors {
            let target = total * CGFloat(k) / CGFloat(anchors)
            while j < dense - 1, len[j + 1] < target { j += 1 }
            let f = (target - len[j]) / max(len[j + 1] - len[j], 1e-9)
            out.append(CGPoint(x: pts[j].x + (pts[j + 1].x - pts[j].x) * f, y: pts[j].y + (pts[j + 1].y - pts[j].y) * f))
        }
        return out
    }

    /// Pushes round puffs out along the outline's normal, one every `anchors / bumps`
    /// points, with a puff on top. With `keepBottom` the base stays flat so it still sits.
    static func puffed(_ base: [CGPoint], bumps: Int, height: CGFloat, keepBottom: Bool = true) -> [CGPoint] {
        let n = base.count
        return base.indices.map { i in
            let a = base[(i + n - 1) % n], b = base[(i + 1) % n]
            let tx = b.x - a.x, ty = b.y - a.y
            let l = max(hypot(tx, ty), 1e-9)
            let nx = ty / l, ny = -tx / l
            var u = CGFloat(i * bumps) / CGFloat(n) + 0.5
            u -= u.rounded(.down)
            let bump = pow(sin(.pi * u), 0.6)
            let fade = keepBottom ? 1 - 0.95 * pow(max(0, ny), 2) : 1
            let d = height * (bump - 0.7) * fade
            let p = CGPoint(x: base[i].x + nx * d, y: base[i].y + ny * d)
            return keepBottom ? CGPoint(x: p.x, y: min(p.y, bottom)) : p
        }
    }

    /// Closed Catmull-Rom spline through the points, as one cubic per point.
    static func smoothPath(through p: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        let n = p.count
        guard n > 2 else { return path }
        path.move(to: p[0])
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    /// The little thought cloud, in its own space centred on zero.
    static func thoughtPath(width: CGFloat, height: CGFloat) -> CGPath {
        let base = outline { CGPoint(x: width / 2 * 0.9 * cos($0), y: height / 2 * 0.82 * sin($0)) }
        return smoothPath(through: puffed(base, bumps: 6, height: min(width, height) * 0.14, keepBottom: false))
    }

}

private extension CGSize {
    func scaled(_ k: CGFloat) -> CGSize { CGSize(width: width * k, height: height * k) }
}

extension CGPath {
    /// How many cubic segments the path has. Morphs need the same count on both ends.
    var cubicCount: Int {
        var n = 0
        applyWithBlock { if $0.pointee.type == .addCurveToPoint { n += 1 } }
        return n
    }
}
