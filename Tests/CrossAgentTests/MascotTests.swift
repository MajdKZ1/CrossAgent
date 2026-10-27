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
        XCTAssertEqual(mood(orch(.working), busy + [node("d", .done, finished: -5)]), .juggling(orbs: ["mac", "pc"]))
        XCTAssertEqual(mood(orch(.working), [busy[1]]), .bobbing(orb: "pc"))
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
        XCTAssertEqual(orbs.last, "mac")
        // n0 started last, so it falls off the end.
        XCTAssertFalse(orbs.contains("pc"))
    }

    func testIdleOthersDontCount() {
        XCTAssertEqual(mood(orch(.idle), [node("a", .idle), node("b", .working, host: "pc")]), .bobbing(orb: "pc"))
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

    func testScript() {
        let s = MascotArt.Script(frames: [1, 0.5, 2])
        XCTAssertEqual(s.frame(at: 0).index, 0)
        XCTAssertEqual(s.frame(at: 1.2).index, 1)
        XCTAssertEqual(s.frame(at: 1.2).remaining, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.frame(at: 3.6).index, 0)
        XCTAssertEqual(s.frame(at: -0.5).index, 2)
    }

    func testIdleRedrawsRarely() {
        let schedule = MascotSchedule(source: .fixed(.idle))
        let dates = Array(schedule.entries(from: now, mode: .normal).prefix(40))
        let span = dates.last!.timeIntervalSince(dates.first!)
        // Breathing plus a blink: about one redraw a second, never a busy loop.
        XCTAssertGreaterThan(span / Double(dates.count - 1), 0.8)
        // Every tick shows a different picture than the last.
        let frames = dates.map { MascotSource.fixed(.idle).state(at: $0).frame }
        for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertNotEqual(MascotArt.frame(.idle, a), MascotArt.frame(.idle, b)) }
    }

    func testPausedTicksOnce() {
        let schedule = MascotSchedule(source: .fixed(.juggling(orbs: ["mac", "pc"])), paused: true)
        XCTAssertEqual(Array(schedule.entries(from: now, mode: .normal).prefix(5)), [now])
    }

    func testScheduleStopsAtMoodChange() {
        // Asleep at +58 s: the schedule should land on that moment, not skip past it.
        let o = orch(.idle, updated: -2)
        let source = MascotSource.graph(orchestrator: o, others: [])
        let dates = Array(MascotSchedule(source: source).entries(from: now, mode: .normal).prefix(200))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(58)))
        XCTAssertEqual(source.mood(at: now.addingTimeInterval(58)), .sleeping)
    }

    func testEveryFrameDraws() {
        for s in MascotGallery.samples {
            for i in 0..<MascotArt.script(s.mood).frames.count {
                let f = MascotArt.frame(s.mood, i)
                XCTAssertGreaterThan(f.px.filter { $0 != 0 }.count, 150, "\(s.name) \(i)")
                XCTAssertFalse(f.px.contains { $0 != 0 && $0 < MascotArt.orbBase && Int($0) > MascotArt.palette.count })
            }
        }
    }

    func testSpritesAreRectangular() {
        XCTAssertEqual(Set(MascotArt.body.map(\.count)), [18])
        for face in MascotArt.Face.allCases {
            XCTAssertEqual(face.rows.count, 6)
            XCTAssertEqual(Set(face.rows.map(\.count)), [12], "\(face)")
        }
        for c in MascotArt.body.joined() where c != "." { XCTAssertTrue(c == "A" || MascotArt.index[c] != nil) }
    }

    /// CROSSAGENT_MASCOT_SNAPSHOT=<dir> swift test --filter MascotTests/testSnapshot
    @MainActor func testSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["CROSSAGENT_MASCOT_SNAPSHOT"] else { throw XCTSkip("no dir") }
        MascotGallery.writeSnapshots(to: URL(fileURLWithPath: dir))
    }
}
