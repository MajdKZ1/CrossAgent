import AppKit
import QuartzCore
import SwiftUI

/// Puff's layer tree. Everything is in design units (`MascotGeometry.size`, y down) and
/// every motion is a Core Animation animation, so the app does no per frame work.
///
///     canvas
///       orbs
///       mover          mood loops: bounce, hop, breathe, shake (pivots on the feet)
///         thought, alert, zzz
///         trick        click tricks (pivots in the middle)
///           body
///           gaze       where the eyes look
///             blinker  blinks (pivots on the eye line)
///               eyes, happy arcs
@MainActor
final class MascotRig {
    let canvas = CALayer()
    let mover = CALayer()
    let trick = CALayer()
    let body = CAShapeLayer()
    let gaze = CALayer()
    let blinker = CALayer()
    let leftEye = CALayer()
    let rightEye = CALayer()
    let leftArc = CAShapeLayer()
    let rightArc = CAShapeLayer()
    let thought = CALayer()
    let thoughtCloud = CAShapeLayer()
    let bubbles = (0..<3).map { _ in CALayer() }
    let alert = CALayer()
    let zzz = CALayer()
    let zs = (0..<3).map { _ in CATextLayer() }
    let orbLayer = CALayer()
    let orbDots = (0..<MascotMood.maxOrbs).map { _ in CALayer() }

    private(set) var mood: MascotMood?
    private(set) var pose = MascotPose()
    /// Where the pointer pulls the eyes while hovering, on top of the pose.
    private var follow: CGPoint = .zero
    private var looped: [(CALayer, String)] = []

    static let orbRadius: CGFloat = 3.6
    static let thoughtCenter = CGPoint(x: 81, y: 14)
    static let alertSpot = CGPoint(x: 84, y: 22)

    init() {
        let g = MascotGeometry.self
        let full = CGRect(origin: .zero, size: g.size)
        canvas.bounds = full
        canvas.anchorPoint = .zero
        canvas.isGeometryFlipped = true

        place(mover, pivot: CGPoint(x: g.center.x, y: g.bottom), in: canvas)
        place(orbLayer, pivot: g.center, in: canvas)
        canvas.insertSublayer(orbLayer, below: mover)
        for dot in orbDots {
            dot.bounds = CGRect(x: 0, y: 0, width: Self.orbRadius * 2, height: Self.orbRadius * 2)
            dot.cornerRadius = Self.orbRadius
            dot.opacity = 0
            dot.position = g.center
            orbLayer.addSublayer(dot)
        }

        // Overlays sit above the head and ride along with hops, but not with spins.
        place(thought, pivot: Self.thoughtCenter, in: mover)
        thoughtCloud.path = MascotGeometry.thoughtPath(width: 25, height: 16.5)
        thoughtCloud.position = Self.thoughtCenter
        thought.addSublayer(thoughtCloud)
        for (i, (p, r)) in [(CGPoint(x: 66, y: 31), 1.3), (CGPoint(x: 70.2, y: 27.4), 1.8), (CGPoint(x: 74.6, y: 24.6), 2.2)].enumerated() {
            let b = bubbles[i]
            b.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            b.cornerRadius = r
            b.position = p
            thought.addSublayer(b)
        }

        place(alert, pivot: CGPoint(x: Self.alertSpot.x, y: Self.alertSpot.y + 12), in: mover)
        let bar = CALayer(), dot = CALayer()
        bar.bounds = CGRect(x: 0, y: 0, width: 4.4, height: 10.5)
        bar.cornerRadius = 2.2
        bar.position = Self.alertSpot
        dot.bounds = CGRect(x: 0, y: 0, width: 4.4, height: 4.4)
        dot.cornerRadius = 2.2
        dot.position = CGPoint(x: Self.alertSpot.x, y: Self.alertSpot.y + 9.4)
        alert.addSublayer(bar)
        alert.addSublayer(dot)

        place(zzz, pivot: CGPoint(x: 72, y: 32), in: mover)
        for (i, z) in zs.enumerated() {
            let size = 7 + CGFloat(i) * 1.8
            z.string = "z"
            z.font = NSFont.systemFont(ofSize: size, weight: .heavy)
            z.fontSize = size
            z.alignmentMode = .center
            z.bounds = CGRect(x: 0, y: 0, width: size, height: size * 1.25)
            z.position = Self.zSpot(i)
            zzz.addSublayer(z)
        }

        place(trick, pivot: g.center, in: mover)
        body.frame = full
        trick.addSublayer(body)
        place(gaze, pivot: MascotPose.eyeLine, in: trick)
        place(blinker, pivot: MascotPose.eyeLine, in: gaze)
        for eye in [leftEye, rightEye] { blinker.addSublayer(eye) }
        for arc in [leftArc, rightArc] {
            arc.bounds = CGRect(x: 0, y: 0, width: 10, height: 8)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 1.6, y: 6.2))
            p.addQuadCurve(to: CGPoint(x: 8.4, y: 6.2), control: CGPoint(x: 5, y: -1.6))
            arc.path = p
            arc.fillColor = nil
            arc.lineWidth = 2.5
            arc.lineCap = .round
            arc.lineJoin = .round
            arc.opacity = 0
            blinker.addSublayer(arc)
        }

        // Plain layers here: nothing animates unless we say so.
        for l in allLayers { l.actions = Self.noActions }
        recolor()
        apply(MascotPose(), animated: false)
    }

    static func zSpot(_ i: Int) -> CGPoint {
        CGPoint(x: 72 + CGFloat(i) * 6.5, y: 28 - CGFloat(i) * 8)
    }

    /// Full canvas sized layer that pivots on `pivot`.
    private func place(_ layer: CALayer, pivot: CGPoint, in parent: CALayer) {
        let s = MascotGeometry.size
        layer.bounds = CGRect(origin: .zero, size: s)
        layer.anchorPoint = CGPoint(x: pivot.x / s.width, y: pivot.y / s.height)
        layer.position = pivot
        parent.addSublayer(layer)
    }

    private var allLayers: [CALayer] {
        [canvas, mover, trick, body, gaze, blinker, leftEye, rightEye, leftArc, rightArc, thought, thoughtCloud,
         alert, zzz, orbLayer] + bubbles + zs + orbDots + alert.sublayers.orEmpty
    }

    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull(), "path": NSNull(),
        "cornerRadius": NSNull(), "backgroundColor": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(),
        "foregroundColor": NSNull(), "contents": NSNull(), "hidden": NSNull(), "sublayers": NSNull(),
    ]

    // MARK: Look

    /// Sharp at `pointsPerUnit` times the backing scale, with room for the canvas zoom.
    func setScale(_ pointsPerUnit: CGFloat, backing: CGFloat) {
        let s = backing * pointsPerUnit * 2
        for l in allLayers { l.contentsScale = s; l.rasterizationScale = s }
    }

    func recolor() {
        let bodyColor = NSColor(Palette.mascotBody)
        let eyes = NSColor(Palette.mascotEyes).cgColor
        let light = (bodyColor.blended(withFraction: 0.3, of: .white) ?? bodyColor).cgColor
        body.fillColor = bodyColor.cgColor
        for e in [leftEye, rightEye] { e.backgroundColor = eyes }
        for a in [leftArc, rightArc] { a.strokeColor = eyes }
        thoughtCloud.fillColor = light
        for b in bubbles { b.backgroundColor = light }
        for l in alert.sublayers.orEmpty { l.backgroundColor = NSColor(Palette.warning).cgColor }
        for z in zs { z.foregroundColor = light }
        for (dot, orb) in zip(orbDots, orbs) { dot.backgroundColor = Self.accent(orb.host) }
    }

    private var orbs: [MascotOrb] { mood?.orbs ?? [] }

    // MARK: Moods

    /// Moves to the mood's pose (springy when animated) and swaps the mood loops.
    func set(_ mood: MascotMood, animated: Bool, loops: Bool = true) {
        guard mood != self.mood else { return }
        let old = self.mood
        self.mood = mood
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(MascotPose.of(mood), animated: animated && old != nil)
        placeOrbs(mood.orbs, animated: animated)
        stopLoops()
        if loops { startLoops(mood) }
        if animated, old != nil {
            if mood == .done { squish(1.1) }
            if mood == .needsInput || old == .sleeping { hop(4) }
        }
        CATransaction.commit()
    }

    func apply(_ pose: MascotPose, animated: Bool) {
        self.pose = pose
        spring(body, "path", MascotGeometry.bodyPath(pose.shape), animated, stiffness: 220, damping: 16)
        for (layer, eye) in [(leftEye, pose.left), (rightEye, pose.right)] {
            spring(layer, "bounds", NSValue(rect: CGRect(origin: .zero, size: eye.size)), animated)
            spring(layer, "position", NSValue(point: eye.center), animated)
            spring(layer, "cornerRadius", eye.cornerRadius, animated)
            spring(layer, "transform.rotation.z", eye.tilt * .pi / 180, animated)
        }
        let eyesOpen: Float = pose.happy ? 0 : 1
        fade(leftEye, to: eyesOpen, animated)
        fade(rightEye, to: eyesOpen, animated)
        leftArc.position = CGPoint(x: MascotPose.restLeft.center.x, y: MascotPose.restLeft.center.y + 1)
        rightArc.position = CGPoint(x: MascotPose.restRight.center.x, y: MascotPose.restRight.center.y + 1)
        fade(leftArc, to: 1 - eyesOpen, animated)
        fade(rightArc, to: 1 - eyesOpen, animated)
        lookAt(follow, animated: animated)
        for (layer, on) in [(thought, pose.thought), (alert, pose.alert), (zzz, pose.zzz)] {
            let target: Float = on ? 1 : 0
            if animated, on, layer.opacity == 0 {
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.4
                pop.toValue = 1
                pop.stiffness = 300
                pop.damping = 14
                pop.duration = pop.settlingDuration
                layer.add(pop, forKey: "pop")
            }
            fade(layer, to: target, animated)
        }
    }

    private func placeOrbs(_ list: [MascotOrb], animated: Bool) {
        let spots = Self.orbSpots(list.count)
        for (i, dot) in orbDots.enumerated() {
            if i < list.count {
                dot.backgroundColor = Self.accent(list[i].host)
                if dot.opacity == 0 { dot.position = MascotGeometry.center }
                spring(dot, "position", NSValue(point: spots[i]), animated, stiffness: 180, damping: 13)
                fade(dot, to: 1, animated)
            } else {
                fade(dot, to: 0, animated)
            }
        }
    }

    /// Orbs float on an arc over the head. One alone sits up and to the right.
    static func orbSpots(_ n: Int) -> [CGPoint] {
        let c = MascotGeometry.center
        let angles: [CGFloat] = n == 1 ? [-38] : (0..<n).map { -158 + 136 * CGFloat($0) / CGFloat(max(n - 1, 1)) }
        return angles.map { a in
            let r = a * .pi / 180
            return CGPoint(x: c.x + 41 * cos(r), y: c.y - 6 + 34 * sin(r))
        }
    }

    // MARK: Gaze

    /// Pulls the eyes toward a point (design units) on top of the pose, or back with nil.
    func look(toward point: CGPoint?) {
        guard let point else {
            follow = .zero
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lookAt(.zero, animated: true)
            CATransaction.commit()
            return
        }
        follow = Self.gazeOffset(toward: point, from: gazeOrigin, reach: 3.6)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        gaze.actions = nil
        gaze.position = CGPoint(x: MascotPose.eyeLine.x + pose.gaze.x + follow.x, y: MascotPose.eyeLine.y + pose.gaze.y + follow.y)
        gaze.actions = Self.noActions
        CATransaction.commit()
    }

    private var gazeOrigin: CGPoint { MascotPose.eyeLine }

    private func lookAt(_ extra: CGPoint, animated: Bool) {
        let p = CGPoint(x: MascotPose.eyeLine.x + pose.gaze.x + extra.x, y: MascotPose.eyeLine.y + pose.gaze.y + extra.y)
        spring(gaze, "position", NSValue(point: p), animated, stiffness: 260, damping: 20)
    }

    static func gazeOffset(toward p: CGPoint, from o: CGPoint, reach: CGFloat) -> CGPoint {
        let dx = p.x - o.x, dy = p.y - o.y
        let len = max(hypot(dx, dy), 0.001)
        let k = reach * min(len / 30, 1) / len
        return CGPoint(x: dx * k, y: dy * k * 0.8)
    }

    // MARK: Loops

    private func stopLoops() {
        for (layer, key) in looped { layer.removeAnimation(forKey: key) }
        looped = []
    }

    private func loop(_ layer: CALayer, _ key: String, _ a: CAAnimation, delay: CFTimeInterval = 0) {
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        if delay != 0 { a.fillMode = .backwards }
        layer.add(a, forKey: "loop." + key)
        looped.append((layer, "loop." + key))
    }

    private func startLoops(_ mood: MascotMood) {
        switch mood {
        case .idle:
            break
        case .thinking:
            loop(thoughtCloud, "float", wave("position.y", 1.2, period: 2.6))
            for (i, b) in bubbles.enumerated() {
                let a = CAKeyframeAnimation(keyPath: "opacity")
                a.values = [0.25, 1, 1, 0.25]
                a.keyTimes = [0, 0.3, 0.7, 1]
                a.duration = 1.8
                loop(b, "rise", group([a, wave("position.y", 0.9, period: 1.8)], duration: 1.8), delay: -Double(i) * 0.6)
            }
            loop(gaze, "drift", path([CGPoint(x: 0, y: 0), CGPoint(x: -1.2, y: 0.4), CGPoint(x: 0.6, y: -0.6), .zero],
                                    duration: 4.2, additive: true, key: "position"))
        case .working:
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, -2.4, 0, 0]
            hop.keyTimes = [0, 0.38, 0.72, 1]
            hop.timingFunctions = [ease(.easeOut), ease(.easeIn), ease(.linear)]
            let sx = keys("transform.scale.x", [1, 0.985, 1.04, 1], [0, 0.38, 0.78, 1])
            let sy = keys("transform.scale.y", [1, 1.02, 0.95, 1], [0, 0.38, 0.78, 1])
            loop(mover, "bounce", group([hop, sx, sy], duration: 0.56))
        case .bobbing(let orb):
            _ = orb
            loop(mover, "bob", wave("transform.translation.y", 1.6, period: 1.15))
            loop(orbDots[0], "float", wave("position.y", 1.8, period: 1.5))
        case .juggling(let orbs):
            loop(mover, "bob", wave("transform.translation.y", 1.1, period: 0.9))
            for i in orbs.indices {
                loop(orbDots[i], "float", wave("position.y", 1.6 + CGFloat(i % 2) * 0.6, period: 1.2 + 0.17 * Double(i)),
                     delay: -0.3 * Double(i))
            }
            // Eyes dart from orb to orb, holding on each one.
            let spots = Self.orbSpots(orbs.count)
            let hold = 0.62
            var values: [CGPoint] = [], times: [Double] = []
            for (i, s) in spots.enumerated() {
                let o = Self.gazeOffset(toward: s, from: gazeOrigin, reach: 3.6)
                let t0 = Double(i) / Double(spots.count)
                values += [o, o]
                times += [t0 + 0.12 / Double(spots.count), t0 + 1 / Double(spots.count)]
            }
            values.insert(values.last!, at: 0)
            times.insert(0, at: 0)
            times[times.count - 1] = 1
            let dart = CAKeyframeAnimation(keyPath: "position")
            dart.values = values.map { NSValue(point: $0) }
            dart.keyTimes = times.map { NSNumber(value: $0) }
            dart.isAdditive = true
            dart.duration = hold * Double(spots.count)
            loop(gaze, "dart", dart)
        case .needsInput:
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, 0, -5, 0, -1.4, 0, 0]
            hop.keyTimes = [0, 0.1, 0.25, 0.4, 0.48, 0.56, 1]
            hop.timingFunctions = [ease(.linear), ease(.easeOut), ease(.easeIn), ease(.easeOut), ease(.easeIn), ease(.linear)]
            let sy = keys("transform.scale.y", [1, 0.92, 1.04, 0.94, 1, 1], [0, 0.1, 0.25, 0.4, 0.5, 1])
            let sx = keys("transform.scale.x", [1, 1.06, 0.98, 1.05, 1, 1], [0, 0.1, 0.25, 0.4, 0.5, 1])
            loop(mover, "hop", group([hop, sy, sx], duration: 1.6))
            loop(alert, "wiggle", keys("transform.rotation.z", [0, 0.18, -0.14, 0.08, 0, 0], [0, 0.12, 0.24, 0.34, 0.42, 1], duration: 1.6))
        case .done:
            let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
            a.values = [0, -3, 0]
            a.keyTimes = [0, 0.45, 1]
            a.timingFunctions = [ease(.easeOut), ease(.easeIn)]
            a.duration = 0.62
            loop(mover, "bounce", a, delay: 0.25)
        case .error:
            let shake = keys("transform.translation.x", [0, -2.2, 2.2, -1.7, 1.5, -0.8, 0, 0],
                             [0, 0.04, 0.09, 0.14, 0.19, 0.24, 0.3, 1], duration: 2.2)
            loop(mover, "shake", shake)
            loop(leftEye, "wobble", additiveWave("transform.rotation.z", 0.12, period: 0.9))
            loop(rightEye, "wobble", additiveWave("transform.rotation.z", 0.16, period: 1.15))
        case .sleeping:
            let sy = wave("transform.scale.y", 0.035, period: 3.8, base: 1)
            let sx = wave("transform.scale.x", 0.012, period: 3.8, base: 1)
            loop(mover, "breathe", group([sy, sx], duration: 3.8))
            for (i, z) in zs.enumerated() {
                let rise = CABasicAnimation(keyPath: "position")
                rise.fromValue = NSValue(point: CGPoint(x: 66, y: 34))
                rise.toValue = NSValue(point: CGPoint(x: 88, y: 6))
                let fade = keys("opacity", [0, 1, 1, 0], [0, 0.2, 0.65, 1])
                let grow = keys("transform.scale", [0.5, 1, 1.15], [0, 0.4, 1])
                loop(z, "rise", group([rise, fade, grow], duration: 3.6), delay: -1.2 * Double(i))
            }
        }
    }

    // MARK: Gestures and tricks

    func blink(double: Bool = false) {
        let a = double ? keys("transform.scale.y", [1, 0.08, 1, 0.08, 1], [0, 0.2, 0.42, 0.62, 1], duration: 0.42)
                       : keys("transform.scale.y", [1, 0.08, 1], [0, 0.4, 1], duration: 0.17)
        blinker.add(a, forKey: "blink")
    }

    /// Eyes go somewhere, hold, come back.
    func glance(_ offset: CGPoint, hold: CFTimeInterval) {
        let total = 0.24 + hold
        let a = path([.zero, offset, offset, .zero], duration: total, additive: true, key: "position",
                     times: [0, 0.12 / total, (0.12 + hold) / total, 1])
        a.timingFunctions = [ease(.easeOut), ease(.linear), ease(.easeInEaseOut)]
        gaze.add(a, forKey: "glance")
    }

    func play(_ move: MascotPlay.Move, rng: inout some RandomNumberGenerator) {
        var delay: CFTimeInterval = 0
        for t in move.tricks {
            delay += play(t, k: move.intensity, delay: delay, rng: &rng)
        }
    }

    /// Adds one trick, starting `delay` from now. Returns how long it takes.
    private func play(_ trickKind: MascotPlay.Trick, k: Double, delay: CFTimeInterval, rng: inout some RandomNumberGenerator) -> CFTimeInterval {
        let k = CGFloat(k)
        let anims: [CAAnimation]
        let target: CALayer
        switch trickKind {
        case .squish:
            let x = CASpringAnimation(keyPath: "transform.scale.x")
            x.fromValue = 1 + 0.28 * k
            x.toValue = 1
            let y = CASpringAnimation(keyPath: "transform.scale.y")
            y.fromValue = 1 - 0.24 * k
            y.toValue = 1
            for s in [x, y] { s.stiffness = 340; s.damping = 9; s.initialVelocity = 0; s.duration = s.settlingDuration }
            anims = [x, y]
            target = trick
        case .spin:
            let turns = k > 1.5 ? 2.0 : 1.0
            let r = CABasicAnimation(keyPath: "transform.rotation.z")
            r.fromValue = 0
            r.toValue = 2 * .pi * turns * (Bool.random(using: &rng) ? 1 : -1)
            r.duration = 0.55 + 0.15 * turns
            r.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
            let up = keys("transform.translation.y", [0, -5 * k, 0], [0, 0.45, 1], duration: r.duration)
            anims = [group([r, up], duration: r.duration)]
            target = trick
        case .jelly:
            let n = 9
            let amp = 0.16 * k
            let xs = (0..<n).map { 1 + amp * sin(CGFloat($0) * .pi / 2) * (1 - CGFloat($0) / CGFloat(n - 1)) }
            let ys = (0..<n).map { 1 - amp * sin(CGFloat($0) * .pi / 2) * (1 - CGFloat($0) / CGFloat(n - 1)) }
            let times = (0..<n).map { Double($0) / Double(n - 1) }
            anims = [group([keys("transform.scale.x", xs, times), keys("transform.scale.y", ys, times)], duration: 0.9)]
            target = trick
        case .peekaboo:
            let shut = keys("transform.scale.y", [1, 0.06, 0.06, 1.25, 1], [0, 0.12, 0.6, 0.75, 1], duration: 1)
            blinker.add(shut, forKey: "peek", delay: delay)
            let dir = CGPoint(x: CGFloat.random(in: -3...3, using: &rng), y: CGFloat.random(in: -2.5...1.5, using: &rng))
            let look = path([.zero, .zero, dir, dir, .zero], duration: 1.6, additive: true, key: "position",
                            times: [0, 0.45, 0.5, 0.85, 1])
            gaze.add(look, forKey: "peekLook", delay: delay)
            return 1.1
        case .ricochet:
            let w = 12 * k, h = 5 * k
            let side: CGFloat = Bool.random(using: &rng) ? 1 : -1
            let pts = [CGPoint.zero, CGPoint(x: w * side, y: -h), CGPoint(x: -w * side * 0.8, y: -h * 1.4),
                       CGPoint(x: w * side * 0.5, y: -h * 0.7), CGPoint(x: -w * side * 0.2, y: -h * 0.3), .zero]
            let move = path(pts, duration: 1.1, additive: true, key: "position")
            move.timingFunctions = Array(repeating: ease(.easeInEaseOut), count: pts.count - 1)
            let tilt = keys("transform.rotation.z", [0, -0.2 * side, 0.18 * side, -0.1 * side, 0.04 * side, 0],
                            [0, 0.2, 0.4, 0.6, 0.8, 1])
            anims = [group([move, tilt], duration: 1.1)]
            target = trick
        }
        var longest: CFTimeInterval = 0
        for (i, a) in anims.enumerated() {
            target.add(a, forKey: "trick.\(i)", delay: delay)
            longest = max(longest, a.duration)
        }
        return longest
    }

    /// The done celebration squish.
    private func squish(_ k: CGFloat) {
        var rng = SplitMix64(seed: 1)
        _ = play(.squish, k: Double(k), delay: 0, rng: &rng)
    }

    private func hop(_ height: CGFloat) {
        trick.add(keys("transform.translation.y", [0, -height, 0], [0, 0.4, 1], duration: 0.36), forKey: "hop")
    }

    // MARK: Pause

    /// Freezes every animation in place (window hidden or covered) and picks up again later.
    func setRunning(_ on: Bool) {
        if on, canvas.speed == 0 {
            let paused = canvas.timeOffset
            canvas.speed = 1
            canvas.timeOffset = 0
            canvas.beginTime = 0
            canvas.beginTime = canvas.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !on, canvas.speed != 0 {
            let t = canvas.convertTime(CACurrentMediaTime(), from: nil)
            canvas.speed = 0
            canvas.timeOffset = t
        }
    }

    var isRunning: Bool { canvas.speed != 0 }

    // MARK: Hit testing

    enum Hit: Equatable { case body, orb(String) }

    func hit(_ p: CGPoint) -> Hit? {
        for (dot, orb) in zip(orbDots, orbs) {
            let c = (dot.presentation() ?? dot).position
            if hypot(p.x - c.x, p.y - c.y) <= Self.orbRadius + 3 { return .orb(orb.id) }
        }
        let bodyPath = (body.presentation() ?? body).path ?? body.path
        if bodyPath?.contains(p) == true { return .body }
        return nil
    }

    // MARK: Helpers

    private func spring(_ layer: CALayer, _ key: String, _ value: Any, _ animated: Bool,
                        stiffness: CGFloat = 320, damping: CGFloat = 19) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: key)
        layer.setValue(value, forKeyPath: key)
        guard animated, let from else { return }
        let a = CASpringAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = value
        a.stiffness = stiffness
        a.damping = damping
        a.duration = a.settlingDuration
        layer.add(a, forKey: "pose." + key)
    }

    private func fade(_ layer: CALayer, to value: Float, _ animated: Bool) {
        let from = (layer.presentation() ?? layer).opacity
        layer.opacity = value
        guard animated, from != value else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = value
        a.duration = 0.18
        layer.add(a, forKey: "pose.opacity")
    }

    private func ease(_ name: CAMediaTimingFunctionName) -> CAMediaTimingFunction { CAMediaTimingFunction(name: name) }

    private func keys(_ key: String, _ values: [CGFloat], _ times: [Double], duration: CFTimeInterval = 0) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = values.map { NSNumber(value: Double($0)) }
        a.keyTimes = times.map { NSNumber(value: $0) }
        if duration > 0 { a.duration = duration }
        return a
    }

    private func path(_ points: [CGPoint], duration: CFTimeInterval, additive: Bool, key: String, times: [Double]? = nil) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = points.map { NSValue(point: $0) }
        if let times { a.keyTimes = times.map { NSNumber(value: $0) } }
        a.isAdditive = additive
        a.duration = duration
        a.calculationMode = .cubic
        return a
    }

    /// Smooth back and forth around the current value (or `base`).
    private func wave(_ key: String, _ amount: CGFloat, period: CFTimeInterval, base: CGFloat? = nil) -> CAAnimation {
        let a = CABasicAnimation(keyPath: key)
        if let base {
            a.fromValue = base
            a.toValue = base + amount
        } else {
            a.fromValue = 0
            a.toValue = -amount
            a.isAdditive = true
        }
        a.duration = period / 2
        a.autoreverses = true
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    private func additiveWave(_ key: String, _ amount: CGFloat, period: CFTimeInterval) -> CAAnimation {
        let a = keys(key, [0, amount, 0, -amount * 0.7, 0], [0, 0.25, 0.5, 0.75, 1], duration: period)
        a.isAdditive = true
        a.calculationMode = .cubic
        return a
    }

    private func group(_ anims: [CAAnimation], duration: CFTimeInterval) -> CAAnimationGroup {
        let g = CAAnimationGroup()
        for a in anims where a.duration == 0 || a.duration > duration { a.duration = duration }
        g.animations = anims
        g.duration = duration
        return g
    }

    // MARK: Host colours

    /// Orb colours from hosts.json, read once. Never writes the file.
    static let accents: [String: String] = {
        var out = Dictionary(uniqueKeysWithValues: HostStore.defaults.map { ($0.id, $0.accent) })
        if let data = try? Data(contentsOf: HostStore.fileURL),
           let file = try? JSONDecoder().decode(HostsFile.self, from: data) {
            for h in file.hosts { out[h.id] = h.accent }
        }
        return out
    }()

    static func accent(_ host: String) -> CGColor {
        // A theme can override host colours (Mono does); hosts.json otherwise.
        (ThemeTokens.shared.resolved.hosts[host] ?? NSColor(hex: accents[host] ?? "#8a909c")).cgColor
    }

    // MARK: Stills

    /// The mood's resting pose drawn into a bitmap. Core Animation doesn't show up in
    /// `cacheDisplay`, so stills render the model layer tree directly.
    static func still(_ mood: MascotMood, side: CGFloat, background: CGColor? = nil) -> CGImage? {
        let rig = MascotRig()
        rig.set(mood, animated: false, loops: false)
        let size = MascotGeometry.size
        let k = side / size.width
        let w = Int(side), h = Int((size.height * k).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        rig.setScale(k, backing: 1)
        // Bitmap contexts are y up and render(in:) ignores the canvas flip, so flip here.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: k, y: -k)
        rig.canvas.render(in: ctx)
        return ctx.makeImage()
    }
}

private extension Optional where Wrapped == [CALayer] {
    var orEmpty: [CALayer] { self ?? [] }
}

private extension CALayer {
    func add(_ a: CAAnimation, forKey key: String, delay: CFTimeInterval) {
        if delay > 0 {
            a.beginTime = convertTime(CACurrentMediaTime(), from: nil) + delay
            a.fillMode = .backwards
        }
        add(a, forKey: key)
    }
}
