@testable import CrossAgent
import XCTest

@MainActor
final class GraphReducerTests: XCTestCase {
    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    private func run(_ events: [AgentEvent], upTo n: Int? = nil) -> AgentGraph {
        let g = AgentGraph()
        for e in events.prefix(n ?? events.count) { g.apply(e, project: "proj", projectPaths: [:]) }
        return g
    }

    // MARK: Real capture: claude -p with one background subagent

    func testPrintSessionStepByStep() {
        let ev = HookFixtures.events(HookFixtures.eventsPrint)
        XCTAssertEqual(ev.count, 14)
        let reader = "acc7d38897638900e"

        var g = run(ev, upTo: 2)
        XCTAssertEqual(g.orchestrator?.state, .thinking)

        g = run(ev, upTo: 3)  // PreToolUse Agent
        XCTAssertEqual(g.orchestrator?.state, .working)
        XCTAssertEqual(g.orchestrator?.activity, "Starting reader: Read a.txt contents")
        XCTAssertEqual(g.orchestrator?.flow, .toNode)

        g = run(ev, upTo: 4)  // SubagentStart comes before the Agent tool returns
        XCTAssertEqual(g.nodes[reader]?.name, "general-purpose")
        XCTAssertEqual(g.nodes[reader]?.state, .thinking)

        g = run(ev, upTo: 5)  // PostToolUse Agent: the real name and prompt
        XCTAssertEqual(g.nodes[reader]?.name, "reader")
        XCTAssertEqual(g.nodes[reader]?.kind, .subagent)
        XCTAssertEqual(g.nodes[reader]?.flow, .toNode)
        XCTAssertTrue(g.nodes[reader]?.prompt?.hasPrefix("Read the file") == true)

        g = run(ev, upTo: 8)  // the reader's Read
        XCTAssertEqual(g.nodes[reader]?.state, .working)
        XCTAssertEqual(g.nodes[reader]?.activity, "Reading a.txt")
        XCTAssertEqual(g.nodes[reader]?.recent, ["Reading a.txt"])
        XCTAssertEqual(g.orchestrator?.recent, ["Starting reader: Read a.txt contents", "Running ls"])

        g = run(ev, upTo: 10)  // Stop with the reader still running
        XCTAssertEqual(g.orchestrator?.state, .waiting(["reader"]))
        XCTAssertEqual(g.orchestrator?.activity, "Waiting on reader")

        g = run(ev, upTo: 11)  // SubagentStop
        XCTAssertEqual(g.nodes[reader]?.state, .done)
        XCTAssertEqual(g.nodes[reader]?.flow, .toOrchestrator)
        XCTAssertEqual(g.nodes[reader]?.finishedAt, at(1010))
        XCTAssertTrue(g.nodes[reader]?.recent.last?.hasPrefix("The file exists.") == true)
        XCTAssertEqual(g.finished, [reader])

        g = run(ev, upTo: 12)  // task notification wakes the orchestrator
        XCTAssertEqual(g.orchestrator?.state, .thinking)
        XCTAssertEqual(g.orchestrator?.activity, "Agent \"Read a.txt contents\" finished")

        g = run(ev, upTo: 13)
        XCTAssertEqual(g.orchestrator?.state, .idle)

        g = run(ev)
        XCTAssertEqual(g.orchestrator?.state, .idle)
        XCTAssertEqual(g.orchestrator?.activity, "Session ended")
        XCTAssertEqual(g.nodes.count, 2)
    }

    // MARK: Real capture: interactive session with permissions and a teammate

    func testTTYSession() {
        let ev = HookFixtures.events(HookFixtures.eventsTTY)
        XCTAssertEqual(ev.count, 33)
        let toucher = "atoucher-a9e051414015c9bc"

        var g = run(ev, upTo: 4)  // PermissionRequest
        XCTAssertEqual(g.orchestrator?.state, .needsInput("Needs permission: Running touch x.txt"))
        g = run(ev, upTo: 5)  // the matching Notification keeps it asking
        XCTAssertEqual(g.orchestrator?.state, .needsInput("Claude needs your permission"))
        g = run(ev, upTo: 6)  // declined, user typed the next prompt
        XCTAssertEqual(g.orchestrator?.state, .thinking)
        g = run(ev, upTo: 10)  // approved: PostToolUse
        XCTAssertEqual(g.orchestrator?.state, .working)

        g = run(ev, upTo: 12)  // Stop, then a hidden helper's SubagentStop
        XCTAssertEqual(g.orchestrator?.state, .idle)
        XCTAssertEqual(g.nodes.count, 1, "hidden helper agents get no node")

        g = run(ev, upTo: 16)  // teammate spawned
        XCTAssertEqual(g.nodes[toucher]?.name, "toucher")
        g = run(ev, upTo: 17)  // Stop: background task id is the teammate's, not its agent id
        XCTAssertEqual(g.orchestrator?.state, .waiting(["toucher"]))

        g = run(ev, upTo: 19)  // teammate asks for permission
        XCTAssertEqual(g.nodes[toucher]?.state, .needsInput("Needs permission: Running touch z.txt"))
        g = run(ev, upTo: 20)  // the orchestrator level Notification belongs to the teammate
        XCTAssertEqual(g.orchestrator?.state, .waiting(["toucher"]))

        g = run(ev, upTo: 22)  // hidden SubagentStop, then approved
        XCTAssertEqual(g.nodes[toucher]?.state, .working)
        g = run(ev, upTo: 23)  // SendMessage to the lead
        XCTAssertEqual(g.nodes[toucher]?.flow, .toOrchestrator)
        XCTAssertEqual(g.nodes[toucher]?.activity, "Messaging team-lead: touch z.txt succeeded")

        g = run(ev)
        XCTAssertEqual(g.nodes[toucher]?.state, .done)
        XCTAssertEqual(g.finished, [toucher])
        XCTAssertEqual(g.orchestrator?.state, .idle, "a done teammate still listed as running is not worth waiting on")
        XCTAssertEqual(g.nodes.count, 2)
    }

    // MARK: Workers

    func testWorkers() {
        let g = AgentGraph()
        let s = "ca-proj-pc-tests"
        g.apply(AgentEvent(ts: 100, ev: "WorkerStart", host: "pc", sid: s, cwd: "/home/me/proj", role: "worker",
                           project: "proj", node: "tests", name: "tests", sum: "swift test", tmux: s))
        XCTAssertEqual(g.nodes[s]?.kind, .worker)
        XCTAssertEqual(g.nodes[s]?.hostId, "pc")
        XCTAssertEqual(g.nodes[s]?.tmuxSession, s)
        XCTAssertEqual(g.nodes[s]?.state, .working)
        XCTAssertEqual(g.nodes[s]?.flow, .toNode)

        // Claude inside the worker asks for permission.
        g.apply(AgentEvent(ts: 101, ev: "PermissionRequest", host: "pc", sid: "x", role: "worker", project: "proj",
                           node: "tests", tool: "Bash", sum: "Needs permission: Running rm -rf build"))
        XCTAssertEqual(g.nodes[s]?.state, .needsInput("Needs permission: Running rm -rf build"))
        g.apply(AgentEvent(ts: 102, ev: "PreToolUse", host: "pc", sid: "x", role: "worker", project: "proj",
                           node: "tests", tool: "Bash", sum: "Running swift test"))
        XCTAssertEqual(g.nodes[s]?.state, .working)
        // A worker on the other host with the same task name is someone else.
        g.apply(AgentEvent(ts: 102, ev: "PreToolUse", host: "mac", sid: "y", role: "worker", project: "proj",
                           node: "tests", tool: "Bash", sum: "Running ls"))
        XCTAssertEqual(g.nodes[s]?.activity, "Running swift test")
        XCTAssertNotNil(g.nodes["ca-proj-mac-tests"])

        g.apply(AgentEvent(ts: 110, ev: "WorkerStop", host: "pc", sid: s, role: "worker", project: "proj",
                           node: "tests", sum: "Executed 48 tests", tmux: s, rc: 0))
        XCTAssertEqual(g.nodes[s]?.state, .done)
        XCTAssertEqual(g.nodes[s]?.flow, .toOrchestrator)
        XCTAssertEqual(g.finished, [s])

        let f = "ca-proj-mac-lint"
        g.apply(AgentEvent(ts: 120, ev: "WorkerStart", host: "mac", sid: f, role: "worker", project: "proj", node: "lint", sum: "swiftlint", tmux: f))
        g.apply(AgentEvent(ts: 121, ev: "WorkerStop", host: "mac", sid: f, role: "worker", project: "proj", node: "lint", sum: "2 errors", tmux: f, rc: 2))
        XCTAssertEqual(g.nodes[f]?.state, .error("exit 2"))
        XCTAssertEqual(g.finished, [s, f])
    }

    // MARK: Rules

    func testIdleAfterQuietAndTick() {
        let g = AgentGraph()
        g.apply(AgentEvent(ts: 100, ev: "WorkerStart", host: "pc", sid: "w", role: "worker", project: "proj", node: "bench", tmux: "w"))
        g.tick(now: at(144))
        XCTAssertEqual(g.nodes["w"]?.state, .working)
        g.tick(now: at(145))
        XCTAssertEqual(g.nodes["w"]?.state, .idle)
        // Activity brings it back.
        g.apply(AgentEvent(ts: 150, ev: "PreToolUse", host: "pc", sid: "c", role: "worker", project: "proj", node: "bench", sum: "Running make"))
        XCTAssertEqual(g.nodes["w"]?.state, .working)
        // needsInput never dozes off.
        g.apply(AgentEvent(ts: 151, ev: "PermissionRequest", host: "pc", sid: "c", role: "worker", project: "proj", node: "bench", sum: "Needs permission"))
        g.tick(now: at(1000))
        XCTAssertEqual(g.nodes["w"]?.state, .needsInput("Needs permission"))
    }

    func testErrorClearsOnNextActivity() {
        let g = AgentGraph()
        g.apply(AgentEvent(ts: 1, ev: "PostToolUseFailure", role: "orchestrator", tool: "Bash", err: "Exit code 1"))
        XCTAssertEqual(g.orchestrator?.state, .error("Exit code 1"))
        g.apply(AgentEvent(ts: 2, ev: "PreToolUse", role: "orchestrator", tool: "Bash", sum: "Running swift build"))
        XCTAssertEqual(g.orchestrator?.state, .working)
        g.apply(AgentEvent(ts: 3, ev: "StopFailure", role: "orchestrator", err: "rate_limit"))
        XCTAssertEqual(g.orchestrator?.state, .error("rate_limit"))
        g.apply(AgentEvent(ts: 4, ev: "UserPromptSubmit", role: "orchestrator", sum: "Asked: try again"))
        XCTAssertEqual(g.orchestrator?.state, .thinking)
    }

    func testFinishedKeepsNewestEight() {
        let g = AgentGraph()
        for i in 0..<10 {
            let id = "w\(i)"
            g.apply(AgentEvent(ts: Double(i * 2), ev: "WorkerStart", host: "mac", sid: id, role: "worker", node: id, tmux: id))
            g.apply(AgentEvent(ts: Double(i * 2 + 1), ev: "WorkerStop", host: "mac", sid: id, role: "worker", node: id, tmux: id, rc: 0))
        }
        XCTAssertEqual(g.finished, (2..<10).map { "w\($0)" })
        XCTAssertNil(g.nodes["w0"])
        XCTAssertNil(g.nodes["w1"])
        XCTAssertNotNil(g.nodes["w2"])
    }

    func testSendMessageFlows() {
        let g = AgentGraph()
        let ev = HookFixtures.events(HookFixtures.eventsPrint)
        for e in ev.prefix(5) { g.apply(e) }
        g.apply(AgentEvent(ts: 2000, ev: "PreToolUse", role: "orchestrator", tool: "SendMessage", sum: "Messaging reader: more", to: "reader"))
        XCTAssertEqual(g.nodes["acc7d38897638900e"]?.flow, .toNode)
        XCTAssertEqual(g.nodes["acc7d38897638900e"]?.flowAt, at(2000))
    }

    func testIgnoresOtherProjectsAndPlainSessions() {
        let g = AgentGraph()
        let mine = AgentEvent(ts: 1, ev: "UserPromptSubmit", host: "mac", cwd: "/Users/me/proj/sub", role: "orchestrator", sum: "Asked: hi")
        XCTAssertTrue(AgentGraph.belongs(mine, project: "proj", projectPaths: ["mac": "/Users/me/proj"]))
        XCTAssertFalse(AgentGraph.belongs(mine, project: "proj", projectPaths: ["mac": "/Users/me/projector"]))
        var other = mine
        other.project = "other"
        XCTAssertFalse(AgentGraph.belongs(other, project: "proj", projectPaths: ["mac": "/Users/me/proj"]))
        let pc = AgentEvent(ts: 1, ev: "WorkerStart", host: "pc", cwd: "/home/me/code/proj", role: "worker")
        XCTAssertTrue(AgentGraph.belongs(pc, project: "proj", projectPaths: ["pc": "code/proj"]))
        XCTAssertFalse(AgentGraph.belongs(pc, project: "proj", projectPaths: ["pc": "code/pro"]))

        XCTAssertFalse(g.apply(other, project: "proj", projectPaths: [:]))
        XCTAssertEqual(g.orchestrator?.state, .idle)
        // A regular Claude pane in the same folder (no role) does not drive the graph.
        g.apply(AgentEvent(ts: 2, ev: "UserPromptSubmit", host: "mac", project: "proj", sum: "Asked: hi"))
        XCTAssertEqual(g.orchestrator?.state, .idle)
    }

    func testDemoScriptHitsEveryState() {
        let start = at(5000)
        let script = DemoEvents.script(slug: "demo", start: start)
        XCTAssertEqual(script.map(\.delay), script.map(\.delay).sorted(), "delays are offsets from the start")
        let g = AgentGraph()
        var seen = Set<String>()
        func record() {
            for n in g.nodes.values {
                switch n.state {
                case .thinking: seen.insert("\(n.kind)-thinking")
                case .working: seen.insert("\(n.kind)-working")
                case .needsInput: seen.insert("\(n.kind)-needsInput")
                case .waiting: seen.insert("\(n.kind)-waiting")
                case .idle: seen.insert("\(n.kind)-idle")
                case .done: seen.insert("\(n.kind)-done")
                case .error: seen.insert("\(n.kind)-error")
                }
            }
        }
        for (_, e) in script {
            XCTAssertTrue(g.apply(e, project: "demo", projectPaths: [:]))
            record()
        }
        g.tick(now: start.addingTimeInterval(80))
        record()
        for s in ["orchestrator-thinking", "orchestrator-working", "orchestrator-waiting", "orchestrator-idle",
                  "subagent-working", "subagent-needsInput", "subagent-done", "subagent-error",
                  "worker-working", "worker-done", "worker-idle"] {
            XCTAssertTrue(seen.contains(s), "demo never shows \(s)")
        }
        XCTAssertEqual(Set(g.others.filter { $0.kind == .worker }.map(\.hostId)), ["mac", "pc"])
        XCTAssertEqual(g.others.filter { $0.kind == .subagent }.count, 3)
    }

    func testDedupe() {
        var d = EventDedupe()
        let e = AgentEvent(ts: 1, ev: "PreToolUse", sid: "s", tuid: "t")
        XCTAssertTrue(d.insert(e))
        XCTAssertFalse(d.insert(e))
        var f = e
        f.ev = "PostToolUse"
        XCTAssertTrue(d.insert(f))
    }

    func testParserIsTolerant() {
        XCTAssertNil(EventFollower.parse(Data("".utf8)))
        XCTAssertNil(EventFollower.parse(Data("not json".utf8)))
        XCTAssertNil(EventFollower.parse(Data(#"{"ev":"Stop"}"#.utf8)))
        XCTAssertEqual(EventFollower.parse(Data(#"{"ts":1,"ev":"Stop","extra":[1,2]}"#.utf8))?.ev, "Stop")
    }
}
