@testable import CrossAgent
import XCTest

/// A pc-worker subagent and the headless worker it runs on the PC draw as one node.
/// Events are hand written from the contract in Contracts.swift ("Remote worker events").
@MainActor
final class RemoteWorkerTests: XCTestCase {
    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    private let proxy = "a5f3c2e1d0b9a8776"
    private let tmux = "ca-proj-pc-tests"
    private let caRemote = "~/.claude/skills/crossagent/scripts/ca remote pc tests --brief .crossagent/briefs/tests.md --timeout 540"

    private func spawn(_ g: AgentGraph, _ aid: String, at ts: Double) {
        g.apply(AgentEvent(ts: ts, ev: "SubagentStart", host: "mac", role: "orchestrator", project: "proj", aid: aid, atype: "pc-worker"))
        g.apply(AgentEvent(ts: ts + 0.1, ev: "PostToolUse", host: "mac", role: "orchestrator", project: "proj",
                           name: "pc-worker", tool: "Agent", prompt: "Run the tests on the PC", to: aid))
    }

    private func bash(_ g: AgentGraph, _ aid: String, _ command: String, at ts: Double) {
        g.apply(AgentEvent(ts: ts, ev: "PreToolUse", host: "mac", role: "orchestrator", project: "proj", aid: aid, atype: "pc-worker",
                           tool: "Bash", sum: "Running " + command, prompt: command))
    }

    private func remote(_ g: AgentGraph, _ ev: String, at ts: Double, sum: String? = nil, prompt: String? = nil, msg: String? = nil,
                        rc: Int? = nil, turn: Int? = nil, csid: String? = nil, path: String? = nil, req: String? = nil) {
        g.apply(AgentEvent(ts: ts, ev: ev, host: "pc", sid: tmux, cwd: "/home/me/proj", role: "remote", project: "proj",
                           node: "tests", sum: sum, prompt: prompt, msg: msg, tmux: tmux, rc: rc, turn: turn, csid: csid,
                           path: path, req: req))
    }

    private func stopProxy(_ g: AgentGraph, _ aid: String, at ts: Double, msg: String = "Tests pass on the PC") {
        g.apply(AgentEvent(ts: ts, ev: "SubagentStop", host: "mac", role: "orchestrator", project: "proj", aid: aid,
                           atype: "pc-worker", msg: msg))
    }

    // MARK: Merging

    func testLinkBeforeEvents() {
        let g = AgentGraph()
        spawn(g, proxy, at: 100)
        bash(g, proxy, caRemote, at: 101)
        let n = g.nodes[proxy]
        XCTAssertEqual(n?.kind, .subagent)
        XCTAssertEqual(n?.name, "pc-worker")
        XCTAssertEqual(n?.hostId, "pc", "draws on the PC side")
        XCTAssertEqual(n?.remote, RemoteInfo(host: "pc", role: "tests", tmuxSession: tmux))

        remote(g, "RemoteStart", at: 103, sum: "Run swift test and report failures", turn: 1, path: "/home/me/proj/.crossagent/remote/tests/brief.md")
        remote(g, "RemoteActivity", at: 104, sum: "Running swift test")
        XCTAssertNil(g.nodes[tmux], "no second node")
        XCTAssertEqual(g.nodes.count, 2)
        XCTAssertEqual(g.nodes[proxy]?.state, .working)
        XCTAssertEqual(g.nodes[proxy]?.activity, "Running swift test")
        XCTAssertEqual(g.nodes[proxy]?.remote?.turn, 1)
        XCTAssertEqual(g.nodes[proxy]?.remote?.briefPath, "/home/me/proj/.crossagent/remote/tests/brief.md")
        XCTAssertTrue(g.isRemoteRunning(proxy))

        remote(g, "RemoteStop", at: 200, sum: "48 tests, 0 failures", rc: 0, turn: 1, csid: "84dd3df9",
               path: "/home/me/proj/.crossagent/remote/tests/result.md")
        XCTAssertEqual(g.nodes[proxy]?.state, .working, "the proxy still has to report back")
        XCTAssertEqual(g.nodes[proxy]?.activity, "Reporting back: 48 tests, 0 failures")
        XCTAssertEqual(g.nodes[proxy]?.remote?.resultPath, "/home/me/proj/.crossagent/remote/tests/result.md")
        XCTAssertEqual(g.nodes[proxy]?.remote?.claudeSession, "84dd3df9")
        XCTAssertFalse(g.isRemoteRunning(proxy))
        XCTAssertEqual(g.finished, [])

        stopProxy(g, proxy, at: 205)
        XCTAssertEqual(g.nodes[proxy]?.state, .done)
        XCTAssertEqual(g.finished, [proxy])
    }

    func testEventsBeforeLinkMerge() {
        let g = AgentGraph()
        spawn(g, proxy, at: 100)
        // The PC follower is ahead of the Mac one.
        remote(g, "RemoteStart", at: 101, sum: "Run swift test", turn: 1)
        remote(g, "RemoteActivity", at: 102, sum: "Reading Package.swift")
        XCTAssertEqual(g.nodes[tmux]?.kind, .worker)
        XCTAssertEqual(g.nodes[tmux]?.hostId, "pc")
        XCTAssertEqual(g.nodes[tmux]?.remote?.role, "tests")

        bash(g, proxy, caRemote, at: 100.5)
        XCTAssertNil(g.nodes[tmux], "the standalone node folds into the proxy")
        XCTAssertEqual(g.nodes.count, 2)
        let n = g.nodes[proxy]
        XCTAssertEqual(n?.kind, .subagent)
        XCTAssertEqual(n?.name, "pc-worker")
        XCTAssertEqual(n?.hostId, "pc")
        XCTAssertEqual(n?.remote?.turn, 1)
        XCTAssertEqual(n?.remote?.tmuxSession, tmux)
        XCTAssertEqual(n?.state, .working)
        XCTAssertEqual(n?.activity, "Reading Package.swift")
        XCTAssertTrue(n?.recent.contains("Reading Package.swift") == true)
        XCTAssertTrue(g.isRemoteRunning(proxy))
    }

    func testFinishedStandaloneMergesIntoLiveProxy() {
        let g = AgentGraph()
        spawn(g, proxy, at: 100)
        remote(g, "RemoteStart", at: 101, turn: 1)
        remote(g, "RemoteStop", at: 110, sum: "All green", rc: 0, turn: 1)
        XCTAssertEqual(g.finished, [tmux])
        bash(g, proxy, caRemote, at: 100.5)
        XCTAssertNil(g.nodes[tmux])
        XCTAssertEqual(g.finished, [], "done only once the proxy is")
        XCTAssertEqual(g.nodes[proxy]?.state, .working)
        XCTAssertTrue(g.nodes[proxy]?.recent.contains("All green") == true)
    }

    func testFollowUpRevivesSameNode() {
        let g = AgentGraph()
        spawn(g, proxy, at: 100)
        bash(g, proxy, caRemote, at: 101)
        remote(g, "RemoteStart", at: 102, sum: "Run the tests", turn: 1)
        remote(g, "RemoteStop", at: 150, sum: "2 failures", rc: 0, turn: 1, csid: "84dd3df9", path: "/r1.md")
        stopProxy(g, proxy, at: 155)
        XCTAssertEqual(g.finished, [proxy])

        // The orchestrator resumes the same pc-worker (SendMessage), which sends a follow-up.
        bash(g, proxy, "ca remote pc tests --brief .crossagent/briefs/tests-2.md", at: 200)
        remote(g, "RemoteStart", at: 201, turn: 2, csid: "84dd3df9")
        XCTAssertEqual(g.nodes.count, 2)
        XCTAssertEqual(g.nodes[proxy]?.state, .working)
        XCTAssertEqual(g.nodes[proxy]?.activity, "Starting turn 2")
        XCTAssertEqual(g.nodes[proxy]?.remote?.turn, 2)
        XCTAssertNil(g.nodes[proxy]?.remote?.resultPath, "a new turn has no result yet")
        XCTAssertNil(g.nodes[proxy]?.finishedAt)
        XCTAssertEqual(g.finished, [])

        remote(g, "RemoteStop", at: 260, sum: "All green", rc: 0, turn: 2, csid: "84dd3df9", path: "/r2.md")
        XCTAssertEqual(g.nodes[proxy]?.state, .working)
        stopProxy(g, proxy, at: 262)
        XCTAssertEqual(g.nodes[proxy]?.state, .done)
        XCTAssertEqual(g.nodes[proxy]?.remote?.resultPath, "/r2.md")
    }

    func testRelinkToNewProxy() {
        let g = AgentGraph()
        let second = "a0e9d8c7b6a5f4e3d"
        spawn(g, proxy, at: 100)
        bash(g, proxy, caRemote, at: 101)
        remote(g, "RemoteStart", at: 102, turn: 1, csid: "84dd3df9")
        remote(g, "RemoteStop", at: 150, sum: "2 failures", rc: 0, turn: 1, csid: "84dd3df9")
        stopProxy(g, proxy, at: 155)

        // A fresh Agent call for the follow-up. The PC's RemoteStart lands before the link.
        spawn(g, second, at: 200)
        remote(g, "RemoteStart", at: 201, sum: "Fix the two failures", turn: 2, csid: "84dd3df9")
        XCTAssertEqual(g.nodes[proxy]?.state, .working, "woken on the old node until the link comes")
        bash(g, second, caRemote, at: 200.5)
        XCTAssertNil(g.nodes[proxy], "the old proxy is gone")
        XCTAssertFalse(g.finished.contains(proxy))
        XCTAssertEqual(g.nodes.count, 2)
        XCTAssertEqual(g.nodes[second]?.remote?.turn, 2)
        XCTAssertEqual(g.nodes[second]?.remote?.claudeSession, "84dd3df9")
        XCTAssertEqual(g.nodes[second]?.hostId, "pc")
        XCTAssertEqual(g.nodes[second]?.activity, "Fix the two failures")

        // Relinking while the old proxy still runs: it is dropped once it finishes.
        let third = "a1b2c3d4e5f6a7b8c"
        spawn(g, third, at: 300)
        bash(g, third, "ca remote wait pc tests", at: 301)
        XCTAssertEqual(g.nodes[third]?.remote?.turn, 2)
        XCTAssertNil(g.nodes[second]?.remote)
        XCTAssertEqual(g.nodes[second]?.hostId, "mac")
        stopProxy(g, second, at: 302)
        XCTAssertNil(g.nodes[second])
        XCTAssertEqual(g.nodes.count, 2)
    }

    func testOrchestratorDrivingAWorkerItself() {
        let g = AgentGraph()
        g.apply(AgentEvent(ts: 100, ev: "PreToolUse", host: "mac", role: "orchestrator", project: "proj", tool: "Bash",
                           sum: "Running ca remote pc tests --brief b.md", prompt: "ca remote pc tests --brief b.md"))
        remote(g, "RemoteStart", at: 101, turn: 1)
        XCTAssertEqual(g.nodes[tmux]?.kind, .worker)
        remote(g, "RemoteStop", at: 120, sum: "Done here", rc: 0, turn: 1)
        XCTAssertEqual(g.nodes[tmux]?.state, .done)

        // A proxied worker the orchestrator later waits on itself finishes on RemoteStop.
        let h = AgentGraph()
        spawn(h, proxy, at: 100)
        bash(h, proxy, caRemote, at: 101)
        remote(h, "RemoteStart", at: 102, turn: 1)
        stopProxy(h, proxy, at: 110, msg: "Still running, wait on it with ca remote wait pc tests")
        h.apply(AgentEvent(ts: 111, ev: "PreToolUse", host: "mac", role: "orchestrator", project: "proj", tool: "Bash",
                           prompt: "ca remote wait pc tests"))
        remote(h, "RemoteActivity", at: 112, sum: "Running swift test")
        XCTAssertEqual(h.nodes[proxy]?.state, .working)
        remote(h, "RemoteStop", at: 130, sum: "All green", rc: 0, turn: 1)
        XCTAssertEqual(h.nodes[proxy]?.state, .done)
        XCTAssertEqual(h.nodes[proxy]?.activity, "All green")
        XCTAssertEqual(h.nodes.count, 2)
    }

    // MARK: State

    func testPermissionAskAndAnswer() {
        let g = AgentGraph()
        spawn(g, proxy, at: 100)
        bash(g, proxy, caRemote, at: 101)
        remote(g, "RemoteStart", at: 102, turn: 1)
        remote(g, "PermissionAsk", at: 110, sum: "Needs permission: Running npm test", prompt: "npm test --silent", req: "r1")
        XCTAssertEqual(g.nodes[proxy]?.state, .needsInput("Needs permission: Running npm test"))
        XCTAssertEqual(g.nodes[proxy]?.remote?.permission,
                       PermissionAsk(id: "r1", host: "pc", text: "Needs permission: Running npm test", detail: "npm test --silent", at: at(110)))

        // Mac side noise doesn't clear it, only the answer does.
        g.apply(AgentEvent(ts: 111, ev: "PostToolUse", host: "mac", role: "orchestrator", project: "proj", aid: proxy, atype: "pc-worker", tool: "Bash"))
        remote(g, "RemoteActivity", at: 112, sum: "Still waiting")
        remote(g, "PermissionAnswer", at: 113, msg: "allow", req: "other")
        XCTAssertEqual(g.nodes[proxy]?.state, .needsInput("Needs permission: Running npm test"))

        remote(g, "PermissionAnswer", at: 120, msg: "allow", req: "r1")
        XCTAssertEqual(g.nodes[proxy]?.state, .working)
        XCTAssertEqual(g.nodes[proxy]?.activity, "Allowed: Running npm test")
        XCTAssertNil(g.nodes[proxy]?.remote?.permission)

        remote(g, "PermissionAsk", at: 130, sum: "Needs permission: Running rm -rf build", req: "r2")
        remote(g, "PermissionAnswer", at: 131, msg: "deny", req: "r2")
        XCTAssertEqual(g.nodes[proxy]?.activity, "Denied: Running rm -rf build")
        remote(g, "PermissionAsk", at: 140, sum: "Needs permission: Running curl x", req: "r3")
        remote(g, "PermissionAnswer", at: 200, msg: "timeout", req: "r3")
        XCTAssertEqual(g.nodes[proxy]?.activity, "No answer, denied")
        XCTAssertEqual(g.nodes[proxy]?.state, .working)
    }

    func testTickLeavesARunningTurnAlone() {
        let g = AgentGraph()
        spawn(g, proxy, at: 100)
        bash(g, proxy, caRemote, at: 101)
        remote(g, "RemoteStart", at: 102, turn: 1)
        g.tick(now: at(102 + AgentGraph.idleAfter * 10))
        XCTAssertEqual(g.nodes[proxy]?.state, .working, "a PC test suite can be quiet for minutes")
        remote(g, "RemoteStop", at: 1000, rc: 0, turn: 1)
        g.tick(now: at(1000 + AgentGraph.idleAfter))
        XCTAssertEqual(g.nodes[proxy]?.state, .idle)
    }

    func testResolveNeedsInputLeavesPendingPermission() {
        let g = AgentGraph(session: "ca-proj-mac-orch")
        spawn(g, proxy, at: 100)
        bash(g, proxy, caRemote, at: 101)
        remote(g, "RemoteStart", at: 102, turn: 1)
        remote(g, "PermissionAsk", at: 110, sum: "Needs permission: Running npm test", req: "r1")
        g.resolveNeedsInput(tmuxSession: "ca-proj-mac-orch", now: at(120))
        g.resolveNeedsInput(tmuxSession: tmux, now: at(120))
        XCTAssertEqual(g.nodes[proxy]?.state, .needsInput("Needs permission: Running npm test"))
    }

    func testStandaloneFinishAndError() {
        let g = AgentGraph()
        remote(g, "RemoteStart", at: 100, sum: "Run the benchmarks", turn: 1)
        XCTAssertEqual(g.nodes[tmux]?.name, "tests")
        XCTAssertEqual(g.nodes[tmux]?.tmuxSession, tmux)
        XCTAssertEqual(g.nodes[tmux]?.activity, "Run the benchmarks")
        remote(g, "RemoteStop", at: 120, sum: "Bench done", rc: 0, turn: 1, path: "/r.md")
        XCTAssertEqual(g.nodes[tmux]?.state, .done)
        XCTAssertEqual(g.nodes[tmux]?.flow, .toOrchestrator)
        XCTAssertEqual(g.finished, [tmux])

        remote(g, "RemoteStart", at: 200, turn: 2)
        XCTAssertEqual(g.nodes[tmux]?.state, .working)
        XCTAssertEqual(g.finished, [])
        remote(g, "RemoteStop", at: 220, sum: "claude crashed", rc: 3, turn: 2)
        XCTAssertEqual(g.nodes[tmux]?.state, .error("exit 3"))
        XCTAssertEqual(g.nodes[tmux]?.activity, "claude crashed")
        XCTAssertEqual(g.finished, [tmux])
    }

    func testOtherProjectsRemoteEventsAreIgnored() {
        let g = AgentGraph()
        let e = AgentEvent(ts: 1, ev: "RemoteStart", host: "pc", sid: "ca-other-pc-tests", role: "remote", project: "other",
                           node: "tests", tmux: "ca-other-pc-tests", turn: 1)
        XCTAssertFalse(g.apply(e, project: "proj", projectPaths: [:]))
        XCTAssertEqual(g.nodes.count, 1)
    }

    // MARK: Transcripts

    func testTranscriptLink() {
        let g = AgentGraph()
        let r = TranscriptReducer(graph: g)
        r.slug = "proj"
        let t0 = at(1_793_112_000)
        var spawnItem = TranscriptItem(id: "1", kind: .toolUse, text: "Starting pc-worker", tool: "Agent", agentId: nil, at: t0)
        spawnItem.toolUseId = "toolu_pc"
        spawnItem.signal = .spawn(name: "pc-worker", prompt: "Run the tests on the PC")
        r.apply(spawnItem)

        // The remote side shows up first, then the subagent's file (not yet tied to its call).
        g.applyRemote(AgentEvent(ts: t0.timeIntervalSince1970 + 2, ev: "RemoteStart", host: "pc", sid: tmux, role: "remote",
                                 project: "proj", node: "tests", sum: "Run the tests", tmux: tmux, turn: 1), at: t0 + 2)
        var call = TranscriptItem(id: "2", kind: .toolUse, text: "Running cd /Users/me/proj", tool: "Bash", agentId: "a9", at: t0 + 1)
        call.command = "cd /Users/me/proj\n" + caRemote
        r.apply(call)
        XCTAssertNil(g.nodes[tmux])
        XCTAssertEqual(g.nodes["a9"]?.remote?.role, "tests")

        r.apply(meta: SubagentMeta(name: "pc-worker", toolUseId: "toolu_pc", finished: false), agentId: "a9", at: t0 + 3)
        XCTAssertNil(g.nodes["a9"])
        XCTAssertEqual(g.nodes["toolu_pc"]?.remote?.tmuxSession, tmux)
        XCTAssertEqual(g.nodes["toolu_pc"]?.hostId, "pc")
        XCTAssertEqual(g.remoteNode(host: "pc", role: "tests"), "toolu_pc")

        g.applyRemote(AgentEvent(ts: t0.timeIntervalSince1970 + 4, ev: "PermissionAsk", host: "pc", sid: tmux, role: "remote",
                                 project: "proj", node: "tests", sum: "Needs permission: Running make", tmux: tmux, req: "q"), at: t0 + 4)
        r.apply(TranscriptItem(id: "3", kind: .toolResult, text: "", tool: "Bash", agentId: "a9", at: t0 + 5))
        XCTAssertEqual(g.nodes["toolu_pc"]?.state, .needsInput("Needs permission: Running make"))
        XCTAssertEqual(g.nodes.count, 2)
    }

    func testTranscriptLinkFromFirstLineOnly() {
        let g = AgentGraph()
        let r = TranscriptReducer(graph: g)
        // Older items have no command, only "Running <first line>".
        r.apply(TranscriptItem(id: "1", kind: .toolUse, text: "Running " + caRemote, tool: "Bash", agentId: "a9", at: at(1)))
        XCTAssertEqual(g.nodes["a9"]?.remote?.role, "tests")
        XCTAssertEqual(g.nodes["a9"]?.remote?.tmuxSession, "", "no slug known yet")
        g.applyRemote(AgentEvent(ts: 2, ev: "RemoteStart", host: "pc", sid: tmux, role: "remote", project: "proj",
                                 node: "tests", tmux: tmux, turn: 1), at: at(2))
        XCTAssertEqual(g.nodes["a9"]?.remote?.tmuxSession, tmux)
    }

    func testParserKeepsTheBashCommand() {
        var p = TranscriptParser(agentId: "a9")
        let line = #"{"type":"assistant","uuid":"u1","timestamp":"2026-10-27T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_b","name":"Bash","input":{"command":"cd x\nca remote pc tests --brief b.md"}}]}}"#
        let items = p.parse(Data(line.utf8))
        XCTAssertEqual(items.first?.text, "Running cd x")
        XCTAssertEqual(items.first?.command, "cd x\nca remote pc tests --brief b.md")
    }

    func testSessionFeedGetsItsProjectsRemoteEvents() {
        let slug = "feedproj\(Int.random(in: 1000...9999))"
        RemoteEventLog.register(project: slug, projectPaths: ["mac": "/Users/me/\(slug)", "pc": slug])
        let mac = Host(id: "mac", name: "Mac", type: .local, target: "", accent: "")
        let feed = SessionFeed(host: mac, sessionId: "s1", cwd: "/Users/me/\(slug)") { _ in NoSource() }
        let other = SessionFeed(host: mac, sessionId: "s2", cwd: "/Users/me/elsewhere") { _ in NoSource() }
        let s = CASessionName.make(slug: slug, host: "pc", task: "tests")
        RemoteEventLog.add([
            AgentEvent(ts: 1, ev: "RemoteStart", host: "pc", sid: s, role: "remote", project: slug, node: "tests", tmux: s, turn: 1),
            AgentEvent(ts: 1, ev: "RemoteStart", host: "pc", sid: "ca-x-pc-tests", role: "remote", project: "x", node: "tests", turn: 1),
            AgentEvent(ts: 1, ev: "PreToolUse", host: "pc", role: "orchestrator", project: slug, tool: "Bash"),
        ], project: slug)
        feed.pullRemoteEvents()
        other.pullRemoteEvents()
        XCTAssertEqual(feed.graph.nodes[s]?.remote?.role, "tests")
        XCTAssertEqual(feed.graph.nodes.count, 2)
        XCTAssertEqual(other.graph.nodes.count, 1)
        // Pulling again applies nothing twice.
        RemoteEventLog.add([AgentEvent(ts: 5, ev: "RemoteStop", host: "pc", sid: s, role: "remote", project: slug, node: "tests",
                                       sum: "ok", tmux: s, rc: 0, turn: 1)], project: slug)
        feed.pullRemoteEvents()
        feed.pullRemoteEvents()
        XCTAssertEqual(feed.graph.nodes[s]?.state, .done)
        XCTAssertEqual(feed.graph.nodes[s]?.recent, ["ok"])
    }

    // MARK: Command parser

    func testCaRemoteTargets() {
        func t(_ c: String) -> [RemoteTarget] { AgentGraph.caRemoteTargets(c) }
        let pcTests = [RemoteTarget(host: "pc", role: "tests")]
        XCTAssertEqual(t(caRemote), pcTests)
        XCTAssertEqual(t("/Users/me/.claude/skills/crossagent/scripts/ca remote pc tests --brief .crossagent/briefs/tests.md --timeout 540"), pcTests)
        XCTAssertEqual(t("ca remote wait pc tests"), pcTests)
        XCTAssertEqual(t("ca remote wait pc tests --timeout 540 2>&1 | tail -40"), pcTests)
        XCTAssertEqual(t("cd /Users/me/proj && ~/.claude/skills/crossagent/scripts/ca remote pc tests --brief b.md"), pcTests)
        XCTAssertEqual(t("mkdir -p .crossagent/briefs; ca remote 'pc' \"tests\" --brief .crossagent/briefs/tests.md"), pcTests)
        XCTAssertEqual(t("ca remote linux tests --brief b.md"), pcTests, "host nicknames resolve like ca does")
        XCTAssertEqual(t("ca remote pc tests --brief a.md && ca remote pc lint --brief b.md"),
                       [RemoteTarget(host: "pc", role: "tests"), RemoteTarget(host: "pc", role: "lint")])
        XCTAssertEqual(t("cat <<'EOF' > b.md\nfix it\nEOF\nca remote pc e2e --brief b.md"), [RemoteTarget(host: "pc", role: "e2e")])
        for none in ["ca remote answer r1 allow", "ca remote status pc tests", "ca remote stop pc tests", "ca remote template",
                     "ca wait pc tests", "ca run pc tests -- make", "echo ca remote", "ca remote", "ca remote pc",
                     "ca remote pc --brief b.md", "cat ca"] {
            XCTAssertEqual(t(none), [], none)
        }
    }
}

private final class NoSource: FeedSource, @unchecked Sendable {
    func start() {}
    func stop() {}
    func shutdown(timeout: TimeInterval) {}
}
