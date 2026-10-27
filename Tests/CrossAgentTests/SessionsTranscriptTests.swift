import XCTest
@testable import CrossAgent

final class SessionsTranscriptTests: XCTestCase {
    private func parse(_ path: String, agentId: String? = nil) -> [TranscriptItem] {
        var p = TranscriptParser(agentId: agentId)
        return p.parse(lines: SessionsFixtures.lines(path))
    }

    func testNoiseIsSkipped() {
        var p = TranscriptParser()
        for noise in [#"{"type":"attachment","attachment":{"type":"date"}}"#, #"{"type":"api-request-blob"}"#,
                      #"{"type":"ai-title","aiTitle":"x"}"#, #"{"type":"queue-operation","operation":"enqueue"}"#,
                      #"{"type":"system","subtype":"stop_hook_summary","uuid":"u"}"#,
                      #"{"type":"system","subtype":"turn_duration","uuid":"u","durationMs":5}"#, "", "not json"] {
            XCTAssertEqual(p.parse(Data(noise.utf8)), [], noise)
        }
        // isMeta reminders are not prompts.
        let meta = #"{"type":"user","isMeta":true,"uuid":"u","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#
        XCTAssertEqual(p.parse(Data(meta.utf8)), [])
    }

    func testBackgroundMain() throws {
        let items = parse("background/main.jsonl")
        let kinds = items.map(\.kind)
        XCTAssertEqual(kinds.first, .user)
        XCTAssertTrue(items[0].text.hasPrefix("Spawn two subagents"))
        XCTAssertFalse(kinds.contains(.thinking), "thinking is off by default")

        let spawns = items.filter { if case .spawn = $0.signal { return true } else { return false } }
        XCTAssertEqual(spawns.map(\.text), ["Starting reader: Read a.txt", "Starting lister: List files with ls"])
        XCTAssertEqual(spawns.map(\.tool), ["Agent", "Agent"])
        XCTAssertEqual(spawns[0].toolUseId, "toolu_k3zUFjI2Ep1KDNyCeRVt0xku")
        if case .spawn(let name, let prompt) = spawns[0].signal {
            XCTAssertEqual(name, "reader")
            XCTAssertTrue(prompt?.contains("a.txt") ?? false)
        }

        let launched = items.compactMap { i -> String? in if case .launched(let a) = i.signal { return a } else { return nil } }
        XCTAssertEqual(launched, ["ad6d5aa77ae248062", "a482a3080426bc88b"])
        let firstResult = try XCTUnwrap(items.first { $0.kind == .toolResult })
        XCTAssertEqual(firstResult.tool, "Agent")
        XCTAssertLessThanOrEqual(firstResult.text.split(separator: "\n").count, TranscriptParser.resultLines + 1)

        let notes = items.filter { if case .finished = $0.signal { return true } else { return false } }
        XCTAssertEqual(notes.count, 2, "one task notification per agent")
        XCTAssertEqual(notes[0].kind, .system)
        XCTAssertEqual(notes[0].text, #"Agent "Read a.txt" finished"#)
        XCTAssertEqual(notes[0].toolUseId, "toolu_k3zUFjI2Ep1KDNyCeRVt0xku")
        if case .finished(let aid, let ok, let result) = notes[0].signal {
            XCTAssertEqual(aid, "ad6d5aa77ae248062")
            XCTAssertTrue(ok)
            XCTAssertTrue(result?.contains("hello from a.txt") ?? false)
        }
        XCTAssertEqual(items.last?.kind, .assistant)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "ids are unique")
    }

    func testSubagentFile() {
        let items = parse("background/subagents/agent-a482a3080426bc88b.jsonl", agentId: "a482a3080426bc88b")
        XCTAssertTrue(items.allSatisfy { $0.agentId == "a482a3080426bc88b" })
        XCTAssertEqual(items.first?.kind, .user, "the brief")
        let use = items.first { $0.kind == .toolUse }
        XCTAssertEqual(use?.tool, "Bash")
        XCTAssertEqual(use?.text, "Running ls -la /private/tmp/ca-sess-probe")
        let result = items.first { $0.kind == .toolResult }
        XCTAssertEqual(result?.tool, "Bash")
        XCTAssertEqual(result?.toolUseId, use?.toolUseId)
        XCTAssertTrue(result?.text.hasSuffix("...") ?? false, "long output trimmed")
        XCTAssertNil(items.first { $0.text.contains("Other agents active") }, "reminders skipped")
    }

    func testThinkingOnlyWhenStored() {
        var p = TranscriptParser(includeThinking: true)
        let empty = #"{"type":"assistant","uuid":"u1","timestamp":"2026-10-27T14:39:19.029Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":""}]}}"#
        let full = #"{"type":"assistant","uuid":"u2","timestamp":"2026-10-27T14:39:19.029Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}"#
        XCTAssertEqual(p.parse(Data(empty.utf8)), [])
        XCTAssertEqual(p.parse(Data(full.utf8)).map(\.kind), [.thinking])
    }

    func testTeammateMain() {
        let items = parse("teammate/main.jsonl")
        XCTAssertEqual(items.filter { $0.kind == .user }.map(\.text), [
            "Use the Bash tool to run exactly: touch /tmp/ca-sess-probe2/made.txt",
            "Use the AskUserQuestion tool to ask me whether I prefer red or blue. Nothing else.",
            "Spawn one background subagent named sleeper with the Agent tool whose only job is to run the Bash command: sleep 8 && echo slept. Then end your turn right away.",
        ])
        XCTAssertTrue(items.contains { $0.kind == .toolUse && $0.text == "Asking a question" })
        let launched = items.compactMap { i -> String? in if case .launched(let a) = i.signal { return a } else { return nil } }
        XCTAssertEqual(launched, ["asleeper-d3f7ace792f5d6fd"])
        let msg = items.first { if case .message = $0.signal { return true } else { return false } }
        XCTAssertEqual(msg?.signal, .message(from: "sleeper", text: "The sleep command finished, and its output was: slept"))
        let idle = items.first { if case .teammateIdle = $0.signal { return true } else { return false } }
        if case .teammateIdle(let name, let result)? = idle?.signal {
            XCTAssertEqual(name, "sleeper")
            XCTAssertTrue(result?.hasPrefix("I ran `sleep 8") ?? false)
        } else {
            XCTFail("no idle notification")
        }
        // The teammate's own brief arrives as a teammate-message from the lead.
        let sub = parse("teammate/subagents/agent-asleeper-d3f7ace792f5d6fd.jsonl", agentId: "asleeper-d3f7ace792f5d6fd")
        XCTAssertEqual(sub.first?.kind, .user)
        XCTAssertTrue(sub.first?.text.hasPrefix("Your only job") ?? false)
        XCTAssertNil(sub.first?.signal)
    }

    func testForegroundResultFinishes() {
        let items = parse("foreground/main.jsonl")
        let done = items.compactMap { i -> (String?, Bool)? in
            if case .finished(let a, let ok, _) = i.signal { return (a, ok) } else { return nil }
        }
        XCTAssertEqual(done.map(\.0), ["ad3eded5e86b523e8", "aae9c288ea200a123"])
        XCTAssertTrue(done.allSatisfy(\.1))
        let spawns = items.compactMap { i -> String? in if case .spawn(let n, _) = i.signal { return n } else { return nil } }
        XCTAssertEqual(spawns, ["reader: read a.txt", "lister: list files with ls"], "no name field: the description")
    }

    func testFailedAgentCall() {
        var p = TranscriptParser()
        let use = #"{"type":"assistant","uuid":"a","timestamp":"2026-10-27T14:39:16.707Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_x","name":"Agent","input":{"description":"d","prompt":"p"}}]}}"#
        let res = #"{"type":"user","uuid":"b","timestamp":"2026-10-27T14:39:17.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_x","is_error":true,"content":"boom"}]}}"#
        _ = p.parse(Data(use.utf8))
        let r = p.parse(Data(res.utf8))
        XCTAssertEqual(r.first?.isError, true)
        XCTAssertEqual(r.first?.signal, .finished(agentId: nil, ok: false, result: "boom"))
    }

    func testTagHelpers() {
        let s = "<task-notification>\n<task-id>abc</task-id>\n<status>killed</status>\n</task-notification>"
        XCTAssertEqual(TranscriptParser.tag(s, "task-id"), "abc")
        XCTAssertNil(TranscriptParser.tag(s, "result"))
        let t = #"x <teammate-message teammate_id="sleeper" color="blue">hi</teammate-message>"#
        XCTAssertEqual(TranscriptParser.tag(t, "teammate-message", open: "<teammate-message "), "hi")
        XCTAssertEqual(TranscriptParser.attr(Substring(t), "teammate_id"), "sleeper")
    }

    func testFeedDecoderDedupesAndTags() {
        var d = FeedDecoder()
        var b = FeedBatch()
        let line = SessionsFixtures.lines("background/main.jsonl").first { $0.range(of: Data("tool_use".utf8)) != nil }!
        d.add(line: Data("m\t".utf8) + line, into: &b)
        d.add(line: Data("m\t".utf8) + line, into: &b)
        XCTAssertEqual(b.items.count, 1, "a replayed line is dropped")
        d.add(line: Data("hb\t{}".utf8), into: &b)
        d.add(line: Data(("meta:a1\t" + #"{"mtime":1793112000,"meta":{"name":"x","finished":true}}"#).utf8), into: &b)
        XCTAssertEqual(b.metas.first?.0, "a1")
        XCTAssertEqual(b.metas.first?.1.finished, true)
        d.add(line: Data("s\tnull".utf8), into: &b)
        XCTAssertNotNil(b.session)
        XCTAssertNil(b.session!)
    }
}

@MainActor
final class SessionsReducerTests: XCTestCase {
    private func graph(_ s: SessionsFixtures.Sample, status: ClaudeSessionStatus? = .ended) -> AgentGraph {
        let g = AgentGraph(orchestratorHost: "mac")
        let r = TranscriptReducer(graph: g)
        r.apply(SessionsFixtures.items(s))
        for sub in SessionsFixtures.subagents(s) { r.apply(meta: sub.meta, agentId: sub.id, at: Date()) }
        if let status { r.applyStatus(status, waitingFor: nil, at: Date()) }
        return g
    }

    func testBackgroundAgentsEndDone() throws {
        let g = graph(SessionsFixtures.background)
        let subs = g.others
        XCTAssertEqual(subs.map(\.name), ["reader", "lister"])
        XCTAssertEqual(subs.map(\.id), ["toolu_k3zUFjI2Ep1KDNyCeRVt0xku", "toolu_T7G9ngXlKpQCojZGMUD3cGCE"])
        XCTAssertTrue(subs.allSatisfy { $0.state == .done && $0.kind == .subagent })
        XCTAssertEqual(g.finished.count, 2)
        let reader = subs[0]
        XCTAssertTrue(reader.recent.contains("Reading a.txt"), "\(reader.recent)")
        XCTAssertTrue(reader.prompt?.contains("a.txt") ?? false)
        XCTAssertEqual(reader.flow, .toOrchestrator)
        XCTAssertEqual(g.orchestrator?.state, .idle)
        XCTAssertEqual(g.orchestrator?.activity, "Session ended")
        XCTAssertNil(g.nodes["ad6d5aa77ae248062"], "agent ids fold into the call's node")
    }

    func testForegroundAgentsEndDone() {
        let g = graph(SessionsFixtures.foreground)
        XCTAssertEqual(g.others.map(\.name), ["reader: read a.txt", "lister: list files with ls"])
        XCTAssertTrue(g.others.allSatisfy { $0.state == .done })
        XCTAssertTrue(g.others[1].recent.contains { $0.hasPrefix("Running ls") }, "\(g.others[1].recent)")
    }

    func testTeammateGoesIdleDone() {
        let g = graph(SessionsFixtures.teammate)
        XCTAssertEqual(g.others.count, 1)
        let s = g.others[0]
        XCTAssertEqual(s.name, "sleeper")
        XCTAssertEqual(s.state, .done)
        XCTAssertTrue(s.recent.contains("Running sleep 8 && echo slept"), "\(s.recent)")
        XCTAssertTrue(s.activity.hasPrefix("I ran sleep 8"), s.activity)
    }

    func testLiveStatusDrivesOrchestrator() {
        let g = AgentGraph(orchestratorHost: "pc")
        let r = TranscriptReducer(graph: g)
        let items = SessionsFixtures.items(SessionsFixtures.background)
        // Up to and including both spawns: agents are live.
        let cut = items.lastIndex { if case .launched = $0.signal { return true } else { return false } }!
        r.apply(Array(items[...cut]))
        XCTAssertEqual(g.others.count, 2)
        XCTAssertTrue(g.others.allSatisfy { $0.state != .done })

        r.applyStatus(.running, waitingFor: nil, at: Date())
        XCTAssertEqual(g.orchestrator?.state, .working)
        r.applyStatus(.waiting, waitingFor: "permission prompt", at: Date())
        XCTAssertEqual(g.orchestrator?.state, .needsInput("Needs permission"))
        r.applyStatus(.waiting, waitingFor: "input needed", at: Date())
        XCTAssertEqual(g.orchestrator?.state, .needsInput("Needs your input"))
        r.applyStatus(.idle, waitingFor: nil, at: Date())
        XCTAssertEqual(g.orchestrator?.state, .waiting(["reader", "lister"]), "idle with live agents waits on them")

        // A subagent line makes it work; the rest finishes them.
        r.apply(Array(items[(cut + 1)...]))
        XCTAssertTrue(g.others.allSatisfy { $0.state == .done })
        XCTAssertEqual(g.orchestrator?.state, .idle)
    }

    func testSubagentWorkingFromItsFile() {
        let g = AgentGraph()
        let r = TranscriptReducer(graph: g)
        let t0 = Date(timeIntervalSince1970: 1_793_112_000)
        var spawn = TranscriptItem(id: "1", kind: .toolUse, text: "Starting x", tool: "Agent", agentId: nil, at: t0)
        spawn.toolUseId = "toolu_1"
        spawn.signal = .spawn(name: "x", prompt: "do it")
        r.apply(spawn)
        XCTAssertEqual(g.nodes["toolu_1"]?.state, .thinking)
        XCTAssertEqual(g.orchestrator?.flow, .toNode)
        // The file shows up before anything links it.
        r.apply(TranscriptItem(id: "2", kind: .toolUse, text: "Running make", tool: "Bash", agentId: "a9", at: t0 + 1))
        XCTAssertEqual(g.nodes["a9"]?.state, .working)
        r.apply(meta: SubagentMeta(name: "x", toolUseId: "toolu_1", finished: false), agentId: "a9", at: t0 + 2)
        XCTAssertNil(g.nodes["a9"])
        XCTAssertEqual(g.nodes["toolu_1"]?.state, .working)
        XCTAssertEqual(g.nodes["toolu_1"]?.recent, ["Running make"])
        r.apply(meta: SubagentMeta(name: "x", toolUseId: "toolu_1", finished: true), agentId: "a9", at: t0 + 3)
        XCTAssertEqual(g.nodes["toolu_1"]?.state, .done)
        // Idle after a quiet spell, as with hooks.
        r.apply(spawn)
        var other = spawn
        other.toolUseId = "toolu_2"
        r.apply(other)
        r.tick(now: t0 + AgentGraph.idleAfter + 1)
        XCTAssertEqual(g.nodes["toolu_2"]?.state, .idle)
    }
}
