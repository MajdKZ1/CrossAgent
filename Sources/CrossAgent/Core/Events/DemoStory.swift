import Foundation

/// Scripted canvas stories for README recordings, played on the demo project's
/// Orchestrator tab while DemoMode is on. Everything goes through the real reducer,
/// plus a few cues the hooks can't send (the Allow click, a worker dozing off, the
/// clear that loops the story). Only generic names, paths and text.
enum DemoStory {
    enum Cue: Equatable {
        case event(AgentEvent)
        /// Allow on the approval card, the same path as the button.
        case allow(node: String)
        /// The node goes quiet, so it shows its zzz.
        case doze(node: String, activity: String)
        /// Every node but the orchestrator leaves, the orchestrator goes back to Ready.
        case clear
    }

    struct Step: Equatable {
        /// Seconds from the start of the story.
        var at: TimeInterval
        var cue: Cue
    }

    static let names = ["hero", "open"]

    /// Node ids, so recordings can aim at them (`{"cmd":"expand","id":"explore"}`).
    static let explore = "explore", implement = "implement", review = "review", pcWorker = "pc-worker"
    /// The pc-worker's remote role, and the `ca run` worker's task.
    static let remoteRole = "tests", benchTask = "bench"
    /// Permission request id. Twelve hex characters, like the real ones.
    static let permissionID = "d3e40a1b2c5f"

    /// When the hero story is done, with `loop` the next run starts here.
    static let heroLength: TimeInterval = 18.2
    /// Gap between the clear and the next run: nodes are back in the orchestrator by then.
    static let loopGap: TimeInterval = 0.8

    static func steps(_ name: String, slug: String = "demo", mac: String = "mac", pc: String = "pc",
                      start: Date = Date()) -> [Step]? {
        switch name {
        case "hero": hero(slug: slug, mac: mac, pc: pc, start: start)
        case "open": open(slug: slug, mac: mac, pc: pc, start: start)
        default: nil
        }
    }

    /// About 18 s: lone orchestrator, thinking, agents popping out on both machines,
    /// waiting on them, an approval on the PC that gets allowed, everyone reporting
    /// back, Puff celebrating, a quiet worker dozing off.
    static func hero(slug: String = "demo", mac: String = "mac", pc: String = "pc", start: Date = Date()) -> [Step] {
        var s = Script(slug: slug, mac: mac, pc: pc, start: start)
        let tests = "ca remote \(pc) \(remoteRole) --brief .crossagent/briefs/tests.md --timeout 900"

        // 0.0 to 1.6: the orchestrator alone with Puff.
        s.orch(0, "SessionStart", sum: "Session started")
        // 1.6 to 3.2: thinking.
        s.orch(1.6, "UserPromptSubmit", sum: "Asked: Make the router faster and get the test suite green on the PC")
        // 3.2 to 7.0: agents pop out one by one.
        s.spawn(3.2, explore, "Map the router",
                "Read docs/api.md and Sources/App/Router.swift. List every route and how it is matched. Report anything slow.")
        s.spawn(4.0, implement, "Faster route matching",
                "Replace the linear route scan in Sources/App/Router.swift with a trie. Keep the public API as it is.")
        s.spawn(4.8, pcWorker, "Test suite on the PC", "Run the full test suite on the PC and report failures with file and line.")
        s.sub(5.3, pcWorker, "PreToolUse", tool: "Bash", sum: "Running " + tests, prompt: tests)
        s.orch(5.5, "PreToolUse", tool: "Bash", sum: "Running ca run \(pc) \(benchTask) -- swift run -c release router-bench")
        s.worker(5.6, benchTask, "WorkerStart", sum: "swift run -c release router-bench")
        s.remote(5.7, "RemoteStart", sum: "Run the full test suite and report failures", turn: 1)
        s.spawn(6.3, review, "Review the change", "Review the router change for correctness and missed edge cases.")
        // 7.0: background agents running, the orchestrator waits on them.
        s.orch(7.0, "Stop", bg: [explore, implement, pcWorker, review],
               msg: "Four agents are on it. I'll merge when they report back.")
        // 7.3 to 9.2: work, with messages moving both ways.
        s.sub(7.3, explore, "PreToolUse", tool: "Read", sum: "Reading docs/api.md")
        s.sub(7.6, implement, "PreToolUse", tool: "Read", sum: "Reading Sources/App/Router.swift")
        s.remote(7.9, "RemoteActivity", tool: "Read", sum: "Reading Tests/RouterTests/RouterTests.swift")
        s.sub(8.2, review, "PreToolUse", tool: "Read", sum: "Reading Sources/App/Router.swift")
        s.sub(8.5, explore, "PreToolUse", tool: "SendMessage", sum: "Messaging team-lead: two routes do a linear scan",
              prompt: "Two routes do a linear scan in Router.match", to: "team-lead")
        s.sub(8.6, implement, "PreToolUse", tool: "Edit", sum: "Editing Sources/App/Router.swift")
        s.sub(8.9, implement, "PreToolUse", tool: "SendMessage", sum: "Messaging review: the trie is in, have a look",
              to: review)
        // 9.2 to 10.8: the PC asks for an approval, then it gets allowed.
        s.remote(9.2, "PermissionAsk", tool: "Bash", sum: "Needs permission: Running swift test --parallel",
                 prompt: "swift test --parallel", req: permissionID)
        s.sub(9.6, explore, "PreToolUse", tool: "Grep", sum: "Searching for func match")
        s.sub(10.1, review, "PreToolUse", tool: "Read", sum: "Reading Tests/RouterTests/TrieTests.swift")
        s.cue(10.8, .allow(node: pcWorker))
        s.sub(11.0, implement, "PreToolUse", tool: "Bash", sum: "Running swift build")
        s.remote(11.4, "RemoteActivity", tool: "Bash", sum: "Running swift test --parallel")
        // 11.8 to 14.6: everyone reports back, Puff celebrates, the bench worker dozes off.
        s.sub(11.8, explore, "SubagentStop", msg: "Mapped all 14 routes. Two did a linear scan, both go through the trie now.")
        s.cue(12.4, .doze(node: s.workerID(benchTask), activity: "Bench done: p50 0.8 ms, was 2.6 ms"))
        s.sub(12.9, review, "SubagentStop", msg: "Looks good. Added a test for trailing slashes.")
        s.remote(13.3, "RemoteStop", sum: "212 tests pass on the PC", rc: 0, turn: 1)
        s.sub(13.7, pcWorker, "SubagentStop", msg: "All 212 tests pass on the PC.")
        s.sub(14.1, implement, "SubagentStop", msg: "Router matches through a trie now, lookups are 3x faster.")
        s.orch(14.6, "Stop", msg: "The router is 3x faster and all 212 tests pass on the PC.")
        // Done cards hold their check mark for 4 s, then shrink and fade. Over at 18.2.
        return s.sorted
    }

    /// A few agents with full cards to open: explore done with its result, implement
    /// and review still at it. Settled in about 3 s.
    static func open(slug: String = "demo", mac: String = "mac", pc: String = "pc", start: Date = Date()) -> [Step] {
        var s = Script(slug: slug, mac: mac, pc: pc, start: start)
        s.orch(0, "SessionStart", sum: "Session started")
        s.orch(0.2, "UserPromptSubmit", sum: "Asked: Make the router faster")
        s.spawn(0.5, explore, "Map the router",
                "Read docs/api.md and Sources/App/Router.swift. List every route and how it is matched. Report anything slow.")
        s.spawn(0.9, implement, "Faster route matching",
                "Replace the linear route scan in Sources/App/Router.swift with a trie. Keep the public API as it is.")
        s.spawn(1.3, review, "Review the change", "Review the router change for correctness and missed edge cases.")
        s.orch(1.7, "Stop", bg: [explore, implement, review], msg: "Three agents are on it.")
        s.sub(1.8, explore, "PreToolUse", tool: "Read", sum: "Reading docs/api.md")
        s.sub(2.0, implement, "PreToolUse", tool: "Read", sum: "Reading Sources/App/Router.swift")
        s.sub(2.1, explore, "PreToolUse", tool: "Read", sum: "Reading Sources/App/Router.swift")
        s.sub(2.3, explore, "PreToolUse", tool: "Grep", sum: "Searching for func match")
        s.sub(2.4, review, "PreToolUse", tool: "Read", sum: "Reading Tests/RouterTests/RouterTests.swift")
        s.sub(2.5, explore, "PreToolUse", tool: "Bash", sum: "Running swift test --filter RouterTests")
        s.sub(2.6, implement, "PreToolUse", tool: "Edit", sum: "Editing Sources/App/Router.swift")
        s.sub(2.8, explore, "SubagentStop",
              msg: "Mapped all 14 routes. /users/:id and /files/* did a linear scan, everything else is a dictionary hit.")
        s.sub(3.0, implement, "PreToolUse", tool: "Edit", sum: "Editing Sources/App/RouteTrie.swift")
        return s.sorted
    }

    /// Builds the steps. Event timestamps are `start + at`, so play each at that moment.
    private struct Script {
        let slug: String, mac: String, pc: String
        let t0: Double
        let sid = "demo-orchestrator"
        var steps: [Step] = []

        init(slug: String, mac: String, pc: String, start: Date) {
            self.slug = slug
            self.mac = mac
            self.pc = pc
            t0 = start.timeIntervalSince1970
        }

        var cwd: String { "/Users/demo/Projects/\(slug)" }

        func workerID(_ task: String) -> String { CASessionName.make(slug: slug, host: pc, task: task) }

        /// In time order, steps at the same moment in the order they were added.
        var sorted: [Step] {
            steps.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        }

        mutating func cue(_ at: TimeInterval, _ c: Cue) { steps.append(Step(at: at, cue: c)) }

        mutating func add(_ at: TimeInterval, _ e: AgentEvent) { cue(at, .event(e)) }

        private var nextTool: String { "toolu_demo\(steps.count)" }

        mutating func orch(_ at: TimeInterval, _ ev: String, tool: String? = nil, sum: String? = nil, name: String? = nil,
                           prompt: String? = nil, to: String? = nil, bg: [String]? = nil, msg: String? = nil) {
            add(at, AgentEvent(ts: t0 + at, ev: ev, host: mac, sid: sid, cwd: cwd, role: "orchestrator", project: slug,
                               name: name, tool: tool, tuid: tool.map { _ in nextTool }, sum: sum, prompt: prompt, to: to,
                               bg: bg, msg: msg))
        }

        mutating func sub(_ at: TimeInterval, _ aid: String, _ ev: String, tool: String? = nil, sum: String? = nil,
                          prompt: String? = nil, to: String? = nil, msg: String? = nil) {
            add(at, AgentEvent(ts: t0 + at, ev: ev, host: mac, sid: sid, cwd: cwd, role: "orchestrator", project: slug,
                               aid: aid, atype: aid, tool: tool, tuid: tool.map { _ in nextTool }, sum: sum, prompt: prompt,
                               to: to, msg: msg))
        }

        /// The Agent call, the subagent starting, the call returning with its id.
        mutating func spawn(_ at: TimeInterval, _ aid: String, _ what: String, _ prompt: String) {
            orch(at, "PreToolUse", tool: "Agent", sum: "Starting \(aid): \(what)", name: aid, prompt: prompt)
            sub(at + 0.3, aid, "SubagentStart")
            orch(at + 0.4, "PostToolUse", tool: "Agent", sum: "Starting \(aid): \(what)", name: aid, prompt: prompt, to: aid)
        }

        mutating func worker(_ at: TimeInterval, _ task: String, _ ev: String, sum: String, rc: Int? = nil) {
            let s = workerID(task)
            add(at, AgentEvent(ts: t0 + at, ev: ev, host: pc, sid: s, cwd: "/home/demo/Projects/\(slug)", role: "worker",
                               project: slug, node: task, name: task, sum: sum, tmux: s, rc: rc))
        }

        /// The pc-worker's remote worker. No brief or result paths: the card has nothing to read.
        mutating func remote(_ at: TimeInterval, _ ev: String, tool: String? = nil, sum: String? = nil,
                             prompt: String? = nil, msg: String? = nil, rc: Int? = nil, turn: Int? = nil, req: String? = nil) {
            let s = workerID(remoteRole)
            add(at, AgentEvent(ts: t0 + at, ev: ev, host: pc, sid: s, cwd: "/home/demo/Projects/\(slug)", role: "remote",
                               project: slug, node: remoteRole, tool: tool, sum: sum, prompt: prompt, msg: msg, tmux: s,
                               rc: rc, turn: turn, csid: turn.map { _ in "demo-remote-session" }, req: req))
        }
    }

    /// The PermissionAnswer the worker's host would send back once the answer landed.
    static func permissionAnswer(host: String, role: String, tmux: String, req: String, allow: Bool,
                                 at: Date = Date()) -> AgentEvent {
        AgentEvent(ts: at.timeIntervalSince1970, ev: "PermissionAnswer", host: host, sid: tmux, role: "remote",
                   node: role, msg: allow ? "allow" : "deny", tmux: tmux, req: req)
    }
}
