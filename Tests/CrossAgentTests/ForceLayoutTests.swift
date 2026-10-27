@testable import CrossAgent
import XCTest

final class ForceLayoutTests: XCTestCase {
    private let center = CGSize(width: 236, height: 150)
    private let node = CGSize(width: 172, height: 92)

    private func settle(_ l: inout ForceLayout, seconds: Double = 8) -> Int {
        var steps = 0
        while steps < Int(seconds * 60) {
            steps += 1
            if !l.step(1.0 / 60) { break }
        }
        return steps
    }

    private func assertNoOverlaps(_ l: ForceLayout, file: StaticString = #filePath, line: UInt = #line) {
        let b = l.bodies
        for i in b.indices {
            XCTAssertFalse(ForceLayout.overlaps(b[i].position, b[i].size, .zero, center, pad: 0),
                           "\(b[i].id) overlaps the orchestrator", file: file, line: line)
            for j in b.indices where j > i {
                XCTAssertFalse(ForceLayout.overlaps(b[i].position, b[i].size, b[j].position, b[j].size, pad: 0),
                               "\(b[i].id) overlaps \(b[j].id)", file: file, line: line)
            }
        }
    }

    func testFirstSlotsAreLeftRightUpDown() {
        var l = ForceLayout(center: center)
        let p = (0..<4).map { l.add(id: "n\($0)", size: node) }
        XCTAssertLessThan(p[0].x, 0); XCTAssertEqual(p[0].y, 0, accuracy: 0.001)
        XCTAssertGreaterThan(p[1].x, 0); XCTAssertEqual(p[1].y, 0, accuracy: 0.001)
        XCTAssertLessThan(p[2].y, 0); XCTAssertEqual(p[2].x, 0, accuracy: 0.001)
        XCTAssertGreaterThan(p[3].y, 0); XCTAssertEqual(p[3].x, 0, accuracy: 0.001)
    }

    func testFreedSlotIsReused() {
        var l = ForceLayout(center: center)
        for i in 0..<3 { l.add(id: "n\(i)", size: node) }
        l.remove("n0")
        let p = l.add(id: "new", size: node)
        XCTAssertLessThan(p.x, 0, "left slot is free again")
    }

    func testSettlesWithoutOverlaps() {
        for count in [1, 4, 6, 14] {
            var l = ForceLayout(center: center)
            for i in 0..<count { l.add(id: "n\(i)", size: node) }
            let steps = settle(&l)
            XCTAssertLessThan(steps, (count > 8 ? 6 : 4) * 60, "\(count) nodes should come to rest")
            assertNoOverlaps(l)
            XCTAssertFalse(l.step(1.0 / 60), "stays at rest")
        }
    }

    /// The straight line from the orchestrator to a node never crosses another card.
    func testCablesDoNotCrossCards() {
        for count in [2, 3, 5, 6, 8, 10, 14] {
            var l = ForceLayout(center: center)
            for i in 0..<count { l.add(id: "n\(i)", size: node) }
            _ = settle(&l)
            for a in l.bodies {
                for b in l.bodies where b.id != a.id {
                    let card = CGSize(width: b.size.width, height: b.size.height - 40)
                    for k in 1..<40 {
                        let t = CGFloat(k) / 40
                        let p = CGPoint(x: a.position.x * t, y: a.position.y * t)
                        XCTAssertFalse(ForceLayout.overlaps(p, .zero, b.position, card, pad: 0),
                                       "\(count) nodes: cable to \(a.id) crosses \(b.id)")
                    }
                }
            }
        }
    }

    func testSpringKeepsNodesNearTheOrchestrator() {
        var l = ForceLayout(center: center)
        l.add(id: "a", size: node)
        l.pin("a", at: CGPoint(x: -900, y: 300))
        l.pin("a", at: nil)
        _ = settle(&l)
        let p = l.body("a")!.position
        XCTAssertLessThan(hypot(p.x, p.y), 450)
    }

    func testPinnedBodiesStayPut() {
        var l = ForceLayout(center: center)
        let spot = CGPoint(x: 400, y: -260)
        l.add(id: "pinned", size: node, pinnedAt: spot)
        for i in 0..<5 { l.add(id: "n\(i)", size: node) }
        _ = settle(&l)
        XCTAssertEqual(l.body("pinned")!.position, spot)
        XCTAssertEqual(l.body("pinned")!.velocity, .zero)
        assertNoOverlaps(l)
    }

    func testSameSpotSeparates() {
        var l = ForceLayout(center: center)
        l.add(id: "a", size: node, pinnedAt: CGPoint(x: -300, y: 0))
        l.add(id: "b", size: node, pinnedAt: CGPoint(x: -300, y: 0))
        l.pin("a", at: nil)
        l.pin("b", at: nil)
        _ = settle(&l)
        assertNoOverlaps(l)
    }

    func testRemovalReflows() {
        var l = ForceLayout(center: center)
        for i in 0..<10 { l.add(id: "n\(i)", size: node) }
        _ = settle(&l)
        let far = l.bodies.map { hypot($0.position.x, $0.position.y) }.max()!
        for i in 0..<8 { l.remove("n\(i)") }
        _ = settle(&l)
        let after = l.bodies.map { hypot($0.position.x, $0.position.y) }.max()!
        XCTAssertLessThan(after, far, "outer nodes drift in once room frees up")
    }

    func testEdgeDistance() {
        let s = CGSize(width: 200, height: 100)
        XCTAssertEqual(ForceLayout.edge(s, CGVector(dx: 1, dy: 0)), 100, accuracy: 0.001)
        XCTAssertEqual(ForceLayout.edge(s, CGVector(dx: 0, dy: -1)), 50, accuracy: 0.001)
        let d = CGFloat(0.5).squareRoot()
        XCTAssertEqual(ForceLayout.edge(s, CGVector(dx: d, dy: d)), 50 / d, accuracy: 0.001)
    }

    @MainActor func testCableSags() {
        let c = CableRenderer.cable(from: .zero, CGSize(width: 100, height: 50), to: CGPoint(x: 400, y: 0),
                                    CGSize(width: 100, height: 50))!
        XCTAssertEqual(c.a.x, 50, accuracy: 0.001)
        XCTAssertEqual(c.b.x, 350, accuracy: 0.001)
        XCTAssertGreaterThan(c.point(at: 0.5).y, 0, "middle hangs below the ends")
        XCTAssertNil(CableRenderer.cable(from: .zero, CGSize(width: 100, height: 50), to: CGPoint(x: 60, y: 0),
                                         CGSize(width: 100, height: 50)), "overlapping boxes get no cable")
    }
}
