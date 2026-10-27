@testable import CrossAgent
import XCTest

final class DemoStoryTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Plays the cues up to `t` seconds into a fresh graph, the way the app does.
    @MainActor func graph(_ steps: [DemoStory.Step], until t: TimeInterval) -> AgentGraph {
        let g = AgentGraph(orchestratorHost: "mac", hosts: HostStore.defaults)
        for s in steps where s.at <= t {
            let at = start.addingTimeInterval(s.at)
            switch s.cue {
            case .event(let e): g.apply(e)
            case .allow(let id):
                let r = g.nodes[id]!.remote!
                g.apply(DemoStory.permissionAnswer(host: r.host, role: r.role, tmux: r.tmuxSession, req: r.permission!.id,
                                                   allow: true, at: at))
            case .doze(let id, let activity):
                g.update(id, at: at) { $0.state = .idle; $0.activity = activity }
            case .clear: XCTFail("hero only clears when looping")
            }
        }
        return g
    }

    @MainActor func mood(_ g: AgentGraph, at t: TimeInterval) -> MascotMood {
        MascotMood.from(g, now: start.addingTimeInterval(t))
    }

    @MainActor func testHeroBeats() {
        let steps = DemoStory.hero(start: start)
        XCTAssertEqual(steps.map(\.at), steps.map(\.at).sorted())
        XCTAssertLessThanOrEqual(steps.last!.at, DemoStory.heroLength)

        // Lone orchestrator, then the thinking cloud.
        var g = graph(steps, until: 1.5)
        XCTAssertEqual(g.nodes.count, 1)
        XCTAssertEqual(mood(g, at: 1.5), .idle)
        g = graph(steps, until: 3.1)
        XCTAssertEqual(g.nodes.count, 1)
        XCTAssertEqual(mood(g, at: 3.1), .thinking)

        // Everyone out, the orchestrator waiting, Puff juggling.
        g = graph(steps, until: 7.5)
        let bench = CASessionName.make(slug: "demo", host: "pc", task: "bench")
        XCTAssertEqual(Set(g.others.map(\.id)), ["explore", "implement", "review", "pc-worker", bench])
        XCTAssertEqual(g.nodes["explore"]?.hostId, "mac")
        XCTAssertEqual(g.nodes[bench]?.hostId, "pc")
        XCTAssertEqual(g.nodes[bench]?.kind, .worker)
        let pcw = g.nodes["pc-worker"]!
        XCTAssertEqual(pcw.kind, .subagent)
        XCTAssertEqual(pcw.hostId, "pc")
        XCTAssertEqual(pcw.remote?.tmuxSession, "ca-demo-pc-tests")
        XCTAssertEqual(g.nodes["orchestrator"]?.state, .waiting(["explore", "implement", "pc-worker", "review"]))
        XCTAssertEqual(g.nodes["orchestrator"]?.activity, "Waiting on explore, implement, pc-worker, review")
        guard case .juggling(let orbs) = mood(g, at: 7.5) else { return XCTFail("not juggling") }
        XCTAssertEqual(orbs.count, 5)

        // The approval, then allowed.
        g = graph(steps, until: 10)
        XCTAssertEqual(g.nodes["pc-worker"]?.remote?.permission?.id, DemoStory.permissionID)
        XCTAssertTrue(AppState.validPermissionID(DemoStory.permissionID))
        XCTAssertEqual(mood(g, at: 10), .needsInput)
        g = graph(steps, until: 11)
        XCTAssertNil(g.nodes["pc-worker"]?.remote?.permission)
        XCTAssertEqual(g.nodes["pc-worker"]?.activity, "Allowed: Running swift test --parallel")

        // Reports back, Puff celebrates, bench dozes off, then Puff calms down.
        g = graph(steps, until: 15)
        for id in ["explore", "implement", "review", "pc-worker"] { XCTAssertEqual(g.nodes[id]?.state, .done, id) }
        XCTAssertEqual(g.nodes[bench]?.state, .idle)
        XCTAssertEqual(g.nodes["orchestrator"]?.state, .idle)
        XCTAssertEqual(mood(g, at: 15), .done)
        XCTAssertEqual(mood(g, at: DemoStory.heroLength), .idle)
    }

    @MainActor func testOpenStoryFillsTheCards() {
        let g = graph(DemoStory.open(start: start), until: 10)
        let explore = g.nodes["explore"]!
        XCTAssertEqual(explore.state, .done)
        XCTAssertTrue(explore.prompt?.contains("Router.swift") == true)
        XCTAssertGreaterThanOrEqual(explore.recent.count, 4)
        XCTAssertTrue(explore.activity.hasPrefix("Mapped all 14 routes"))
        XCTAssertEqual(g.nodes["implement"]?.state, .working)
    }

    /// Nothing from this machine or its user ends up in a story or the fake sessions.
    @MainActor func testOnlyMadeUpText() {
        var text = ""
        for name in DemoStory.names {
            for s in DemoStory.steps(name, start: start)! {
                guard case .event(let e) = s.cue else { continue }
                text += String(decoding: try! JSONEncoder().encode(e), as: UTF8.self)
            }
        }
        for s in DemoSessions.list(mac: "mac", pc: "pc") {
            text += s.title + s.sessionId
            for i in DemoSessions.items(sessionId: s.sessionId) { text += i.text }
        }
        XCTAssertFalse(text.contains(NSUserName()))
        XCTAssertFalse(text.contains(Host.current().localizedName ?? "\u{0}"))
        XCTAssertFalse(text.contains("—"))
    }

    func testDemoSessionsList() {
        let list = DemoSessions.list(mac: "mac", pc: "pc")
        XCTAssertEqual(list.map(\.status), [.running, .waiting, .ended, .ended])
        XCTAssertEqual(list.filter(\.isRunning).map(\.hostId), ["mac", "pc"])
        XCTAssertTrue(list.allSatisfy { $0.tmuxSession == nil })
        XCTAssertEqual(list[0].title, "Refactor the router")
    }
}
