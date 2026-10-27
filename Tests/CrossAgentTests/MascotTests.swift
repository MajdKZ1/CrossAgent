@testable import CrossAgent
import SwiftUI
import XCTest

final class MascotTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func node(_ id: String, _ state: AgentState, host: String = "mac", kind: AgentKind = .worker,
              started: Double = 0, updated: Double = -1, finished: Double? = nil) -> AgentNode {
        AgentNode(id: id, name: id, kind: kind, hostId: host, state: state, activity: "",
                  startedAt: now.addingTimeInterval(-100 + started), updatedAt: now.addingTimeInterval(updated),
                  finishedAt: finished.map { now.addingTimeInterval($0) })
    }

    func orch(_ state: AgentState, updated: Double = -1) -> AgentNode {
        node("orchestrator", state, kind: .orchestrator, updated: updated)
    }

    func mood(_ o: AgentNode?, _ others: [AgentNode], at t: Double = 0) -> MascotMood {
        MascotMood.from(orchestrator: o, others: others, now: now.addingTimeInterval(t))
    }

    func testPriority() {
        let busy = [node("a", .working, host: "mac", started: 1), node("b", .thinking, host: "pc", started: 2)]
        XCTAssertEqual(mood(orch(.working), busy + [node("x", .error("boom"))]), .error)
        XCTAssertEqual(mood(orch(.error("x")), []), .error)
        XCTAssertEqual(mood(orch(.working), busy + [node("q", .needsInput("ok?"))]), .needsInput)
        XCTAssertEqual(mood(orch(.working), busy + [node("d", .done, finished: -1)]), .done)
        XCTAssertEqual(mood(orch(.working), busy + [node("d", .done, finished: -5)]),
                       .juggling(orbs: [MascotOrb(id: "a", host: "mac"), MascotOrb(id: "b", host: "pc")]))
        XCTAssertEqual(mood(orch(.working), [busy[1]]), .bobbing(orb: MascotOrb(id: "b", host: "pc")))
        XCTAssertEqual(mood(orch(.working), []), .working)
        XCTAssertEqual(mood(orch(.thinking), []), .thinking)
        XCTAssertEqual(mood(orch(.waiting(["a"])), []), .thinking)
        XCTAssertEqual(mood(orch(.idle), []), .idle)
        XCTAssertEqual(mood(nil, []), .idle)
    }

    func testStaleErrorFades() {
        let failed = node("w", .error("rc 1"), updated: -5, finished: -5)
        XCTAssertEqual(mood(orch(.idle), [failed]), .error)
        XCTAssertEqual(mood(orch(.idle), [failed], at: 14.9), .error)
        XCTAssertEqual(mood(orch(.idle), [failed], at: 15), .idle)
        XCTAssertEqual(MascotMood.nextChange(orchestrator: orch(.idle, updated: -5), others: [failed], after: now),
                       now.addingTimeInterval(15))
        // Still running (not finished): stays an error however old.
        XCTAssertEqual(mood(orch(.idle), [node("r", .error("x"), updated: -500)]), .error)
        XCTAssertEqual(mood(orch(.error("x"), updated: -500), []), .error)
    }

    func testJugglingOrderAndCap() {
        let others = (0..<7).map { node("n\($0)", .working, host: $0 == 0 ? "pc" : "mac", started: Double(7 - $0)) }
        guard case .juggling(let orbs) = mood(orch(.idle), others) else { return XCTFail() }
        XCTAssertEqual(orbs.count, MascotMood.maxOrbs)
        XCTAssertEqual(orbs.map(\.id), ["n6", "n5", "n4", "n3", "n2"])
        // n0 started last, so it falls off the end.
        XCTAssertFalse(orbs.map(\.host).contains("pc"))
    }

    func testIdleOthersDontCount() {
        XCTAssertEqual(mood(orch(.idle), [node("a", .idle), node("b", .working, host: "pc")]), .bobbing(orb: MascotOrb(id: "b", host: "pc")))
    }

    func testDoneWindowAndSleep() {
        let o = orch(.idle, updated: -10)
        let d = node("d", .done, updated: -10, finished: -2)
        XCTAssertEqual(mood(o, [d]), .done)
        XCTAssertEqual(mood(o, [d], at: 1.5), .idle)
        XCTAssertEqual(mood(o, [d], at: 57), .idle)
        XCTAssertEqual(mood(o, [d], at: 58), .sleeping)
        // Done without a finish time falls back to its last update.
        XCTAssertEqual(mood(o, [node("e", .done, updated: -1)]), .done)
        XCTAssertEqual(MascotMood.nextChange(orchestrator: o, others: [d], after: now), now.addingTimeInterval(1))
        XCTAssertEqual(MascotMood.nextChange(orchestrator: o, others: [d], after: now.addingTimeInterval(1)),
                       now.addingTimeInterval(58))
        XCTAssertNil(MascotMood.nextChange(orchestrator: o, others: [d], after: now.addingTimeInterval(60)))
    }

    func testSleepNeedsEverythingIdle() {
        XCTAssertEqual(mood(orch(.idle, updated: -61), []), .sleeping)
        XCTAssertEqual(mood(orch(.thinking, updated: -600), []), .thinking)
    }

    func testSourceChangesOverTime() {
        let source = MascotSource.graph(orchestrator: orch(.idle, updated: -2), others: [])
        XCTAssertEqual(source.nextChange(after: now), now.addingTimeInterval(58))
        XCTAssertEqual(source.mood(at: now.addingTimeInterval(57.9)), .idle)
        XCTAssertEqual(source.mood(at: now.addingTimeInterval(58)), .sleeping)
        XCTAssertNil(MascotSource.fixed(.idle).nextChange(after: now))
    }

    // MARK: Shapes

    func testEveryShapeMorphsPointForPoint() {
        for shape in MascotBodyShape.allCases {
            XCTAssertEqual(MascotGeometry.bodyPoints(shape).count, MascotGeometry.anchors, "\(shape)")
            XCTAssertEqual(MascotGeometry.bodyPath(shape).cubicCount, MascotGeometry.anchors, "\(shape)")
        }
        XCTAssertEqual(MascotGeometry.thoughtPath(width: 20, height: 14).cubicCount, MascotGeometry.anchors)
    }

    func testShapesStayInTheirSpot() {
        let g = MascotGeometry.self
        for shape in MascotBodyShape.allCases {
            let box = g.bodyPath(shape).boundingBoxOfPath
            XCTAssertGreaterThan(box.minX, 0, "\(shape)")
            XCTAssertLessThan(box.maxX, g.size.width, "\(shape)")
            // Sits on the bottom edge, so it rests on the card.
            XCTAssertEqual(box.maxY, g.size.height, accuracy: 3.5, "\(shape)")
            XCTAssertLessThanOrEqual(box.maxY, g.size.height + 0.01, "\(shape)")
            XCTAssertGreaterThan(box.width, box.height * 0.95, "\(shape)")
        }
    }

    func testCloudIsBumpierThanSquircle() {
        func wobble(_ s: MascotBodyShape) -> CGFloat {
            let c = MascotGeometry.center
            let r = MascotGeometry.bodyPoints(s).map { hypot($0.x - c.x, $0.y - c.y) }
            // Sum of second differences: how much the radius goes up and down.
            return (0..<r.count).reduce(0) { $0 + abs(r[($1 + 1) % r.count] - 2 * r[$1] + r[($1 + r.count - 1) % r.count]) }
        }
        XCTAssertGreaterThan(wobble(.cloud), wobble(.puffy))
        XCTAssertGreaterThan(wobble(.puffy), wobble(.squircle))
    }

    // MARK: Poses

    func testEveryMoodHasAFace() {
        var faces: [String: [MascotEye]] = [:]
        for s in MascotGallery.samples {
            let p = MascotPose.of(s.mood)
            for e in [p.left, p.right] {
                XCTAssertGreaterThan(e.size.width, 0, s.name)
                XCTAssertGreaterThan(e.size.height, 0, s.name)
                XCTAssertLessThanOrEqual(e.cornerRadius, min(e.size.width, e.size.height) / 2 + 1e-9, s.name)
                // Eyes stay on the face.
                XCTAssertNotNil(MascotGeometry.bodyPath(p.shape).contains(e.center) ? true : nil, s.name)
            }
            faces[s.name] = [p.left, p.right]
        }
        // Every mood that shows eye bars has its own eyes, apart from the two orb moods.
        let distinct = ["idle", "thinking", "working", "needsInput", "error", "sleeping"].map { faces[$0]! }
        XCTAssertEqual(Set(distinct.map { "\($0)" }).count, distinct.count)
        XCTAssertTrue(MascotPose.of(.done).happy)
        XCTAssertLessThan(MascotPose.of(.sleeping).left.size.height, 3)
        XCTAssertGreaterThan(MascotPose.of(.needsInput).left.size.height, MascotPose.of(.idle).left.size.height)
        XCTAssertLessThan(MascotPose.of(.working).left.size.height, MascotPose.of(.idle).left.size.height)
        XCTAssertNotEqual(MascotPose.of(.error).left.tilt, MascotPose.of(.error).right.tilt)
    }

    func testMoodShapesAndOverlays() {
        XCTAssertEqual(MascotPose.of(.idle).shape, .squircle)
        XCTAssertEqual(MascotPose.of(.thinking).shape, .cloud)
        XCTAssertEqual(MascotPose.of(.working).shape, .puffy)
        XCTAssertEqual(MascotPose.of(.sleeping).shape, .round)
        XCTAssertTrue(MascotPose.of(.thinking).thought)
        XCTAssertTrue(MascotPose.of(.needsInput).alert)
        XCTAssertTrue(MascotPose.of(.sleeping).zzz)
        XCTAssertFalse(MascotPose.of(.idle).thought || MascotPose.of(.idle).alert || MascotPose.of(.idle).zzz)
    }

    // MARK: Clicks

    func testClicksNeverRepeatAndEscalate() {
        var rng = SplitMix64(seed: 42)
        var play = MascotPlay()
        var moves: [MascotPlay.Move] = []
        for i in 0..<12 { moves.append(play.click(at: Double(i) * 0.5, using: &rng)) }
        let flat = moves.flatMap(\.tricks)
        for (a, b) in zip(flat, flat.dropFirst()) { XCTAssertNotEqual(a, b) }
        XCTAssertEqual(moves[0].tricks.count, 1)
        XCTAssertEqual(moves[0].intensity, 1)
        XCTAssertGreaterThan(moves[1].intensity, moves[0].intensity)
        XCTAssertEqual(moves[2].tricks.count, 2)
        XCTAssertEqual(moves[11].intensity, 1.9, accuracy: 1e-9)
        // Every trick shows up in a run this long.
        XCTAssertEqual(Set(flat).count, MascotPlay.Trick.allCases.count)
        // A pause resets the streak.
        let calm = play.click(at: 100, using: &rng)
        XCTAssertEqual(calm.intensity, 1)
        XCTAssertEqual(calm.tricks.count, 1)
        XCTAssertNotEqual(calm.tricks[0], flat.last)
    }

    func testClicksAreRepeatableWithASeed() {
        func run() -> [MascotPlay.Move] {
            var rng = SplitMix64(seed: 7)
            var play = MascotPlay()
            return (0..<8).map { play.click(at: Double($0) * 2, using: &rng) }
        }
        XCTAssertEqual(run(), run())
    }

    // MARK: Rig

    @MainActor func testRigSwapsLoopsPerMood() {
        let rig = MascotRig()
        rig.set(.working, animated: false)
        XCTAssertNotNil(rig.mover.animation(forKey: "loop.bounce"))
        rig.set(.sleeping, animated: true)
        XCTAssertNil(rig.mover.animation(forKey: "loop.bounce"))
        XCTAssertNotNil(rig.mover.animation(forKey: "loop.breathe"))
        XCTAssertNotNil(rig.zs[2].animation(forKey: "loop.rise"))
        XCTAssertEqual(rig.zzz.opacity, 1)
        // Morph from round to squircle springs the path.
        rig.set(.idle, animated: true)
        XCTAssertNotNil(rig.body.animation(forKey: "pose.path"))
        XCTAssertEqual(rig.zzz.opacity, 0)
        XCTAssertTrue(rig.mover.animationKeys()?.filter { $0.hasPrefix("loop.") }.isEmpty ?? true)
    }

    @MainActor func testOrbsAreClickable() {
        let orbs = [MascotOrb(id: "w1", host: "mac"), MascotOrb(id: "w2", host: "pc"), MascotOrb(id: "w3", host: "pc")]
        let rig = MascotRig()
        rig.set(.juggling(orbs: orbs), animated: false, loops: false)
        let spots = MascotRig.orbSpots(3)
        XCTAssertEqual(rig.hit(spots[1]), .orb("w2"))
        XCTAssertEqual(rig.hit(MascotGeometry.center), .body)
        XCTAssertNil(rig.hit(CGPoint(x: 2, y: 88)))
        XCTAssertEqual(rig.orbDots[0].opacity, 1)
        XCTAssertEqual(rig.orbDots[3].opacity, 0)
        // Orbs stay inside the view and off the body.
        for n in 1...MascotMood.maxOrbs {
            for p in MascotRig.orbSpots(n) {
                XCTAssertTrue(CGRect(origin: .zero, size: MascotGeometry.size).insetBy(dx: 3, dy: 3).contains(p))
                XCTAssertFalse(MascotGeometry.bodyPath(.puffy).contains(p))
            }
        }
    }

    @MainActor func testPauseAndResume() {
        let rig = MascotRig()
        XCTAssertTrue(rig.isRunning)
        rig.setRunning(false)
        XCTAssertFalse(rig.isRunning)
        rig.setRunning(true)
        XCTAssertTrue(rig.isRunning)
    }

    @MainActor func testTricksAddAnimations() {
        var rng = SplitMix64(seed: 3)
        let rig = MascotRig()
        rig.set(.idle, animated: false)
        for t in MascotPlay.Trick.allCases {
            rig.play(MascotPlay.Move(tricks: [t], intensity: 1.3), rng: &rng)
        }
        XCTAssertNotNil(rig.trick.animationKeys())
        XCTAssertNotNil(rig.blinker.animation(forKey: "peek"))
    }

    @MainActor func testFollowsAGraph() {
        let graph = AgentGraph()
        let view = MascotLayerView(frame: CGRect(origin: .zero, size: MascotLayerView.size(scale: 0.75)))
        view.follow(graph)
        XCTAssertEqual(view.rig.mood, .idle)
        graph.nodes["w"] = node("w", .working, host: "pc")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(view.rig.mood, .bobbing(orb: MascotOrb(id: "w", host: "pc")))
    }

    @MainActor func testStillsDraw() throws {
        let img = try XCTUnwrap(MascotRig.still(.idle, side: 200))
        XCTAssertEqual(img.width, 200)
        XCTAssertEqual(img.height, 180)
    }

    /// CROSSAGENT_MASCOT_SNAPSHOT=<dir> swift test --filter MascotTests/testSnapshot
    @MainActor func testSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["CROSSAGENT_MASCOT_SNAPSHOT"] else { throw XCTSkip("no dir") }
        MascotGallery.writeSnapshots(to: URL(fileURLWithPath: dir))
    }
}
