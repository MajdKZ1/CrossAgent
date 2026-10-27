import Foundation

/// A scripted, realistic event stream that walks the graph through every state:
/// orchestrator thinking, working, waiting and idle; three built-in subagents; a
/// permission prompt; a done, an error and a quiet (idle) node; a Mac and a PC
/// worker; message flows. Feed it to `AgentGraph.apply(_:)` and call `tick(now:)`
/// now and then so the quiet worker dozes off.
enum DemoEvents {
    /// `delay` is seconds from the start of the script (not from the previous event).
    /// Event timestamps are `start + delay`, so play each event at that moment.
    static func script(slug: String, start: Date = Date()) -> [(delay: TimeInterval, event: AgentEvent)] {
        let t0 = start.timeIntervalSince1970
        let sid = "demo-orchestrator"
        let cwd = "/Users/me/\(slug)"
        var out: [(TimeInterval, AgentEvent)] = []

        func orch(_ at: TimeInterval, _ ev: String, tool: String? = nil, sum: String? = nil, name: String? = nil,
                  prompt: String? = nil, to: String? = nil, bg: [String]? = nil, msg: String? = nil, err: String? = nil) {
            out.append((at, AgentEvent(ts: t0 + at, ev: ev, host: "mac", sid: sid, cwd: cwd, role: "orchestrator",
                                       project: slug, name: name, tool: tool, tuid: tool.map { _ in "toolu_demo\(out.count)" },
                                       sum: sum, prompt: prompt, to: to, bg: bg, msg: msg, err: err)))
        }
        func sub(_ at: TimeInterval, _ aid: String, _ type: String, _ ev: String, tool: String? = nil, sum: String? = nil,
                 to: String? = nil, msg: String? = nil, err: String? = nil) {
            out.append((at, AgentEvent(ts: t0 + at, ev: ev, host: "mac", sid: sid, cwd: cwd, role: "orchestrator",
                                       project: slug, aid: aid, atype: type, tool: tool,
                                       tuid: tool.map { _ in "toolu_demo\(out.count)" }, sum: sum, to: to, msg: msg, err: err)))
        }
        func spawn(_ at: TimeInterval, _ aid: String, _ name: String, _ what: String, _ prompt: String) {
            orch(at, "PreToolUse", tool: "Agent", sum: "Starting \(name): \(what)", name: name, prompt: prompt)
            sub(at + 0.3, aid, name, "SubagentStart")
            orch(at + 0.4, "PostToolUse", tool: "Agent", sum: "Starting \(name): \(what)", name: name, prompt: prompt, to: aid)
        }
        func worker(_ at: TimeInterval, _ host: String, _ task: String, _ ev: String, sum: String, rc: Int? = nil) {
            let s = CASessionName.make(slug: slug, host: host, task: task)
            out.append((at, AgentEvent(ts: t0 + at, ev: ev, host: host, sid: s,
                                       cwd: ev == "WorkerStart" ? (host == "mac" ? cwd : "/home/me/\(slug)") : nil,
                                       role: "worker", project: slug, node: task, name: task, sum: sum, tmux: s, rc: rc)))
        }
        func workerClaude(_ at: TimeInterval, _ host: String, _ task: String, _ ev: String, tool: String? = nil, sum: String? = nil) {
            out.append((at, AgentEvent(ts: t0 + at, ev: ev, host: host, sid: "demo-\(host)-\(task)", cwd: "/home/me/\(slug)",
                                       role: "worker", project: slug, node: task, tool: tool, sum: sum)))
        }

        let ui = "a1demo0ui0builder", term = "a2demo0terminal0e", ver = "a3demo0verifier00"

        orch(0, "SessionStart", sum: "Session started")
        orch(1, "UserPromptSubmit", sum: "Asked: Add a settings screen for hosts and get the test suite green on the PC")
        orch(3, "PreToolUse", tool: "Read", sum: "Reading SPEC.md")
        orch(4.5, "PostToolUse", tool: "Read", sum: "Reading SPEC.md")
        spawn(5, ui, "ui-builder", "Settings screen", "Build a Settings window listing hosts from hosts.json with add, edit and reset. Match Theme.swift.")
        spawn(6.5, term, "terminal-engineer", "Host reachability", "Add a reachability check per host using the ssh control master. No new dependencies.")
        spawn(8, ver, "verifier", "Check the build", "Build and run the test suite, report failures with file and line.")
        sub(9, ui, "ui-builder", "PreToolUse", tool: "Read", sum: "Reading SettingsView.swift")
        orch(10, "Stop", bg: [ui, term, ver], msg: "Three agents are on it. I'll merge when they report back.")
        sub(10.5, term, "terminal-engineer", "PreToolUse", tool: "Grep", sum: "Searching for ControlPath")
        sub(12, ui, "ui-builder", "PreToolUse", tool: "Edit", sum: "Editing SettingsView.swift")
        sub(13, ver, "verifier", "PreToolUse", tool: "Bash", sum: "Running swift build")
        worker(14, "mac", "lint", "WorkerStart", sum: "swiftlint --strict")
        worker(15, "pc", "tests", "WorkerStart", sum: "swift test --parallel")
        worker(16, "pc", "bench", "WorkerStart", sum: "./scripts/bench.sh --long")
        sub(17, term, "terminal-engineer", "PreToolUse", tool: "Edit", sum: "Editing Hosts.swift")
        sub(18, term, "terminal-engineer", "PreToolUse", tool: "Bash", sum: "Running ssh pc 'tmux ls'")
        sub(18.2, term, "terminal-engineer", "PermissionRequest", tool: "Bash", sum: "Needs permission: Running ssh pc 'tmux ls'")
        orch(18.3, "Notification", tool: "permission_prompt", sum: "Claude needs your permission", msg: "Claude needs your permission")
        workerClaude(19, "pc", "tests", "PreToolUse", tool: "Bash", sum: "Running swift test --parallel")
        sub(20, ui, "ui-builder", "PreToolUse", tool: "Edit", sum: "Editing Theme.swift")
        sub(23, ui, "ui-builder", "PreToolUse", tool: "SendMessage", sum: "Messaging verifier: settings view is in, please build", to: "verifier")
        sub(24, term, "terminal-engineer", "PostToolUse", tool: "Bash", sum: "Running ssh pc 'tmux ls'")
        sub(25, ui, "ui-builder", "SubagentStop", msg: "Added SettingsView with the host list, edit sheet and a reset button. Build is clean.")
        orch(25.5, "UserPromptSubmit", sum: "Agent \"Settings screen\" finished", to: ui)
        orch(26.5, "PreToolUse", tool: "Read", sum: "Reading SettingsView.swift")
        orch(28, "Stop", bg: [term, ver], msg: "ui-builder is done. Waiting on the other two.")
        worker(27, "mac", "lint", "WorkerStop", sum: "Done. 0 violations, 0 serious in 42 files.", rc: 0)
        sub(29, ver, "verifier", "PreToolUse", tool: "Bash", sum: "Running swift test")
        sub(30, term, "terminal-engineer", "PreToolUse", tool: "Edit", sum: "Editing SyncMonitor.swift")
        workerClaude(31, "pc", "tests", "PreToolUse", tool: "Read", sum: "Reading GraphReducerTests.swift")
        sub(33, ver, "verifier", "PostToolUseFailure", tool: "Bash", sum: "Running swift test", err: "3 tests failed in GraphReducerTests")
        sub(35, term, "terminal-engineer", "PreToolUse", tool: "SendMessage", sum: "Messaging team-lead: reachability check is in", to: "team-lead")
        sub(36, term, "terminal-engineer", "SubagentStop", msg: "Hosts now show reachable or not, checked through the control master every 30 s.")
        orch(36.5, "UserPromptSubmit", sum: "Agent \"Host reachability\" finished", to: term)
        worker(38, "pc", "tests", "WorkerStop", sum: "Executed 48 tests, with 0 failures (0 unexpected) in 6.2 s", rc: 0)
        orch(39, "PreToolUse", tool: "Bash", sum: "Running git diff --stat")
        orch(41, "PreToolUse", tool: "SendMessage", sum: "Messaging verifier: rerun with the fix in main", to: "verifier")
        orch(43, "Stop", msg: "Settings and reachability are in, tests are green on the PC. The verifier hit 3 failures, details on its node.")
        return out.sorted { $0.0 < $1.0 }
    }
}
