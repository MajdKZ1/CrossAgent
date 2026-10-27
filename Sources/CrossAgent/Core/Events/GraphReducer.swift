import Foundation

/// Turns `AgentEvent`s into `AgentGraph` state. Deterministic: time comes from the
/// events and from `tick(now:)`, never from the clock.
///
/// Field use beyond the obvious, as written by crossagent-hook.py:
/// - Agent tool PostToolUse: `to` is the spawned agent's id, `name` its name.
/// - UserPromptSubmit carrying a `<task-notification>`: `to` is the finished task id.
/// - Notification: `tool` is the notification_type (permission_prompt, idle_prompt, ...).
extension AgentGraph {
    /// Nodes with no event for this long while busy fall back to idle.
    static let idleAfter: TimeInterval = 45
    /// Finished nodes kept on the canvas.
    static let keepFinished = 8
    /// Lines kept in a node's `recent`.
    static let keepRecent = 6
    /// A permission Notification this close to a subagent's PermissionRequest belongs to it.
    static let permissionPairing: TimeInterval = 3

    private static let needsInputNotifications: Set<String> = [
        "permission_prompt", "worker_permission_prompt", "agent_needs_input", "elicitation_dialog",
    ]

    /// True when the event is about this project: same `project` slug when the event
    /// has one, else a cwd inside the project's folder on that host. `projectPaths`
    /// maps host id to the project folder (absolute, or relative to $HOME on ssh hosts).
    /// An empty slug and no paths accept everything.
    nonisolated static func belongs(_ e: AgentEvent, project: String, projectPaths: [String: String]) -> Bool {
        if let p = e.project, !p.isEmpty { return project.isEmpty || p == project }
        if project.isEmpty && projectPaths.isEmpty { return true }
        guard let cwd = e.cwd, let host = e.host, let root = projectPaths[host], !root.isEmpty else { return false }
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        if r.hasPrefix("/") { return cwd == r || cwd.hasPrefix(r + "/") }
        // Relative to an unknown remote $HOME: match on the tail.
        return cwd.hasSuffix("/" + r) || cwd.contains("/" + r + "/")
    }

    /// Applies the event when it belongs to this project. Returns whether it did.
    @discardableResult
    func apply(_ e: AgentEvent, project: String, projectPaths: [String: String]) -> Bool {
        guard Self.belongs(e, project: project, projectPaths: projectPaths) else { return false }
        apply(e)
        return true
    }

    /// Applies one event with no project filter.
    func apply(_ e: AgentEvent) {
        let t = Date(timeIntervalSince1970: e.ts)
        if e.ev == "WorkerStart" || e.ev == "WorkerStop" { applyWorker(e, t); return }
        if e.ev == "SendMessage" { return }
        if e.role == "worker" { applyWorkerClaude(e, t); return }
        if e.role != "orchestrator" { return }
        if let aid = e.aid, !aid.isEmpty { applySubagent(aid, e, t); return }
        applyOrchestrator(e, t)
    }

    func apply(_ events: [AgentEvent], project: String, projectPaths: [String: String]) {
        for e in events { apply(e, project: project, projectPaths: projectPaths) }
    }

    /// Time based transitions: busy workers and subagents quiet for `idleAfter` go idle.
    func tick(now: Date) {
        for (id, n) in nodes where n.kind != .orchestrator {
            switch n.state {
            case .thinking, .working:
                if now.timeIntervalSince(n.updatedAt) >= Self.idleAfter {
                    update(id, at: nil) { $0.state = .idle }
                }
            default: break
            }
        }
    }

    // MARK: Orchestrator

    private func applyOrchestrator(_ e: AgentEvent, _ t: Date) {
        let o = Self.orchestratorID
        switch e.ev {
        case "SessionStart":
            update(o, at: t) { $0.state = .idle; $0.activity = "Ready" }
        case "UserPromptSubmit":
            if let task = e.to, nodes[task] != nil {
                // A background agent reported back.
                finish(task, at: t, message: nil)
            }
            update(o, at: t) { $0.state = .thinking; $0.activity = e.sum ?? "Thinking" }
        case "PreToolUse":
            update(o, at: t) {
                $0.state = .working
                $0.activity = e.sum ?? "Working"
                if let s = e.sum { Self.push(s, into: &$0.recent) }
            }
            if e.tool == "Agent" || e.tool == "Task" { flow(o, .toNode, t) }
            if e.tool == "SendMessage", let to = e.to { messageSent(to: to, from: nil, at: t) }
            if e.tool == "Bash" {
                // `ca wait <host> <task>...` blocks on workers until its PostToolUse.
                let command = e.prompt ?? e.sum.map { $0.hasPrefix("Running ") ? String($0.dropFirst(8)) : $0 } ?? ""
                let tasks = Self.caWaitTasks(command)
                if !tasks.isEmpty {
                    update(o, at: t) { $0.state = .waiting(tasks); $0.activity = "Waiting on " + tasks.joined(separator: ", ") }
                }
            }
        case "PostToolUse":
            if e.tool == "Agent" || e.tool == "Task", let id = e.to, !id.isEmpty {
                spawned(id, e, t)
            }
            update(o, at: t) { n in
                if Self.isBusyOrStuck(n.state) { n.state = .working }
            }
        case "PostToolUseFailure", "StopFailure":
            update(o, at: t) { $0.state = .error(e.err ?? "Something failed"); $0.activity = e.err ?? "Failed" }
        case "PermissionRequest":
            update(o, at: t) { Self.ask(&$0, e.sum ?? "Needs permission", specific: true) }
        case "Notification":
            guard let kind = e.tool, Self.needsInputNotifications.contains(kind) else { return }
            // Subagent permission prompts also send an orchestrator Notification.
            if others.contains(where: { if case .needsInput = $0.state { return abs($0.updatedAt.timeIntervalSince(t)) < Self.permissionPairing } else { return false } }) { return }
            let text = e.msg ?? e.sum ?? "Needs your input"
            update(o, at: t) { Self.ask(&$0, text) }
        case "PermissionDenied":
            update(o, at: t) { $0.activity = "Denied: " + (e.err ?? e.sum ?? "tool call") }
        case "Stop":
            let names = waitingNames(e.bg ?? [])
            update(o, at: t) {
                $0.state = names.isEmpty ? .idle : .waiting(names)
                $0.activity = names.isEmpty ? (e.msg ?? "Idle") : "Waiting on " + names.joined(separator: ", ")
                if let m = e.msg { Self.push(m, into: &$0.recent) }
            }
        case "SessionEnd":
            update(o, at: t) { $0.state = .idle; $0.activity = "Session ended" }
        default:
            break
        }
    }

    /// Stop's background ids that match a live node name it. Ids that match nothing
    /// (teammate task ids) stand for the subagents still running. Never workers there:
    /// those are waited on through `ca wait`.
    private func waitingNames(_ bg: [String]) -> [String] {
        let live = { (n: AgentNode) -> Bool in
            switch n.state {
            case .done, .error: return false
            default: return true
            }
        }
        var names = bg.compactMap { id -> String? in nodes[id].flatMap { live($0) ? $0.name : nil } }
        if bg.contains(where: { nodes[$0] == nil }) {
            for n in others where n.kind == .subagent && live(n) && !names.contains(n.name) {
                names.append(n.name)
            }
        }
        return names
    }

    /// Task names in a `ca wait <host> <task> [<host> <task>...] [--timeout s]` command,
    /// anywhere in a shell line. Empty when there is none.
    nonisolated static func caWaitTasks(_ command: String) -> [String] {
        var tasks: [String] = []
        for line in command.components(separatedBy: CharacterSet(charactersIn: "\n;|&()")) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            guard let i = words.indices.first(where: {
                (words[$0] == "ca" || words[$0].hasSuffix("/ca")) && $0 + 1 < words.count && words[$0 + 1] == "wait"
            }) else { continue }
            var args: [String] = []
            var j = i + 2
            while j < words.count {
                if words[j] == "--timeout" { j += 2; continue }
                if words[j].hasPrefix("-") || words[j].hasPrefix(">") || words[j].hasPrefix("2>") { break }
                args.append(words[j])
                j += 1
            }
            guard args.count >= 2 else { continue }
            for k in stride(from: 1, to: args.count, by: 2) where !tasks.contains(args[k]) { tasks.append(args[k]) }
        }
        return tasks
    }

    // MARK: Needs input, resolved from the screen

    /// The app's screen check says `tmuxSession` no longer waits for input (approving a
    /// permission sends no hook event). Every node asking through that session goes back
    /// to working: the orchestrator and its subagents for the orchestrator's session, a
    /// worker for its own.
    func resolveNeedsInput(tmuxSession: String, now: Date = Date()) {
        let orchestratorSession = orchestrator?.tmuxSession == tmuxSession
        for (id, n) in nodes {
            guard case .needsInput = n.state else { continue }
            let mine: Bool
            switch n.kind {
            case .orchestrator, .subagent: mine = orchestratorSession
            case .worker: mine = n.tmuxSession == tmuxSession
            }
            guard mine else { continue }
            update(id, at: now) {
                if case .waiting(let names)? = $0.resumeState {
                    $0.state = .waiting(names)
                    $0.activity = "Waiting on " + names.joined(separator: ", ")
                    return
                }
                $0.state = .working
                let prefix = "Needs permission: "
                if $0.activity.hasPrefix(prefix) {
                    $0.activity = String($0.activity.dropFirst(prefix.count))
                } else {
                    $0.activity = $0.recent.last ?? "Working"
                }
            }
        }
    }

    // MARK: Built-in subagents

    /// Agent tool returned: the agent id is known now.
    private func spawned(_ id: String, _ e: AgentEvent, _ t: Date) {
        let name = e.name ?? nodes[id]?.name ?? "agent"
        if nodes[id] == nil {
            nodes[id] = AgentNode(id: id, name: name, kind: .subagent, hostId: e.host ?? "mac", state: .thinking,
                                  activity: "Starting", prompt: e.prompt, startedAt: t, updatedAt: t)
        }
        update(id, at: t) {
            $0.name = name
            if let p = e.prompt { $0.prompt = p }
            $0.flow = .toNode
            $0.flowAt = t
        }
    }

    private func applySubagent(_ aid: String, _ e: AgentEvent, _ t: Date) {
        if nodes[aid] == nil {
            // Claude Code runs hidden helpers (prompt suggestions and such) with no
            // agent_type. Only real agents get a node.
            guard e.ev == "SubagentStart" || e.ev == "PreToolUse" || e.ev == "PermissionRequest",
                  let type = e.atype, !type.isEmpty else { return }
            nodes[aid] = AgentNode(id: aid, name: type, kind: .subagent, hostId: e.host ?? "mac", state: .thinking,
                                   activity: "Starting", startedAt: t, updatedAt: t, flow: .toNode, flowAt: t)
        }
        switch e.ev {
        case "SubagentStart":
            update(aid, at: t) { if $0.state != .done { $0.state = .thinking } }
        case "PreToolUse":
            revive(aid)
            // A handback (or a message to the lead) carries the agent's report. Show it,
            // so it is also the result when SubagentStop comes with no message.
            let report = Self.isReport(e) ? e.prompt.flatMap { $0.isEmpty ? nil : $0 } : nil
            update(aid, at: t) {
                $0.state = .working
                $0.activity = report ?? e.sum ?? "Working"
                if let s = report ?? e.sum { Self.push(s, into: &$0.recent) }
            }
            if e.tool == "SendMessage", let to = e.to { messageSent(to: to, from: aid, at: t) }
        case "PostToolUse":
            update(aid, at: t) { n in if Self.isBusyOrStuck(n.state) { n.state = .working } }
        case "PostToolUseFailure", "StopFailure":
            update(aid, at: t) { $0.state = .error(e.err ?? "Something failed"); $0.activity = e.err ?? "Failed" }
        case "PermissionRequest":
            revive(aid)
            update(aid, at: t) { Self.ask(&$0, e.sum ?? "Needs permission", specific: true) }
        case "Notification":
            guard let kind = e.tool, Self.needsInputNotifications.contains(kind) else { return }
            update(aid, at: t) { Self.ask(&$0, e.msg ?? "Needs your input") }
        case "SubagentStop":
            finish(aid, at: t, message: e.msg)
        default:
            break
        }
    }

    // MARK: Workers

    private func applyWorker(_ e: AgentEvent, _ t: Date) {
        guard let id = e.tmux ?? e.sid, !id.isEmpty else { return }
        let host = e.host ?? "mac"
        if e.ev == "WorkerStart" {
            if nodes[id] != nil { revive(id) }
            let n = AgentNode(id: id, name: e.node ?? e.name ?? id, kind: .worker, hostId: host, state: .working,
                              activity: e.sum.map { "Running " + $0 } ?? "Starting", tmuxSession: id,
                              prompt: e.sum, recent: [], startedAt: t, updatedAt: t, flow: .toNode, flowAt: t)
            nodes[id] = n
            return
        }
        // WorkerStop
        if nodes[id] == nil {
            nodes[id] = AgentNode(id: id, name: e.node ?? e.name ?? id, kind: .worker, hostId: host, state: .working,
                                  activity: "", tmuxSession: id, startedAt: t, updatedAt: t)
        }
        let rc = e.rc ?? 0
        if rc == 0 {
            finish(id, at: t, message: e.sum)
        } else {
            update(id, at: t) {
                $0.state = .error("exit \(rc)")
                $0.activity = e.sum ?? "Exited with \(rc)"
                if let s = e.sum { Self.push(s, into: &$0.recent) }
                $0.flow = .toOrchestrator
                $0.flowAt = t
                $0.finishedAt = t
            }
            markFinished(id)
        }
    }

    /// Claude Code hook events from inside a `ca run --claude` worker.
    private func applyWorkerClaude(_ e: AgentEvent, _ t: Date) {
        guard let task = e.node, !task.isEmpty else { return }
        let host = e.host ?? "mac"
        let id = nodes.values.first { $0.kind == .worker && $0.hostId == host && $0.name == task }?.id
            ?? CASessionName.make(slug: e.project ?? "", host: host, task: task)
        if nodes[id] == nil {
            nodes[id] = AgentNode(id: id, name: task, kind: .worker, hostId: host, state: .thinking, activity: "Starting",
                                  tmuxSession: id, startedAt: t, updatedAt: t, flow: .toNode, flowAt: t)
        }
        if case .done = nodes[id]?.state { return }
        if case .error = nodes[id]?.state, e.ev != "PreToolUse", e.ev != "UserPromptSubmit" { return }
        switch e.ev {
        case "UserPromptSubmit":
            update(id, at: t) { $0.state = .thinking; $0.activity = e.sum ?? "Thinking" }
        case "PreToolUse":
            update(id, at: t) {
                $0.state = .working
                $0.activity = e.sum ?? "Working"
                if let s = e.sum { Self.push(s, into: &$0.recent) }
            }
            if e.aid == nil, e.tool == "SendMessage", let to = e.to { messageSent(to: to, from: id, at: t) }
        case "PostToolUse":
            update(id, at: t) { n in if Self.isBusyOrStuck(n.state) { n.state = .working } }
        case "PermissionRequest":
            update(id, at: t) { Self.ask(&$0, e.sum ?? "Needs permission", specific: true) }
        case "Notification":
            guard let kind = e.tool, Self.needsInputNotifications.contains(kind) else { return }
            update(id, at: t) { Self.ask(&$0, e.msg ?? "Needs your input") }
        case "Stop" where e.aid == nil:
            update(id, at: t) {
                $0.state = .idle
                if let m = e.msg { $0.activity = m; Self.push(m, into: &$0.recent) }
            }
        case "StopFailure":
            update(id, at: t) { $0.state = .error(e.err ?? "Something failed"); $0.activity = e.err ?? "Failed" }
        default:
            break
        }
    }

    // MARK: Helpers

    private func messageSent(to: String, from: String?, at t: Date) {
        let lead: Set<String> = ["team-lead", "main", "lead", "orchestrator"]
        if lead.contains(to.lowercased()) {
            if let from { flow(from, .toOrchestrator, t) }
            return
        }
        if let target = nodes[to]?.id ?? others.first(where: { $0.name == to })?.id {
            flow(target, .toNode, t)
        }
    }

    private func flow(_ id: String, _ f: CableFlow, _ t: Date) {
        guard nodes[id] != nil else { return }
        nodes[id]!.flow = f
        nodes[id]!.flowAt = t
    }

    private func finish(_ id: String, at t: Date, message: String?) {
        guard let n = nodes[id], n.state != .done else { return }
        update(id, at: t) {
            $0.state = .done
            if let m = message, !Self.oneLine(m).isEmpty {
                $0.activity = m
                Self.push(m, into: &$0.recent)
            } else if $0.activity.isEmpty {
                $0.activity = "Done"
            }
            $0.flow = .toOrchestrator
            $0.flowAt = t
            $0.finishedAt = t
        }
        markFinished(id)
    }

    private func markFinished(_ id: String) {
        finished.removeAll { $0 == id }
        finished.append(id)
        while finished.count > Self.keepFinished {
            let old = finished.removeFirst()
            nodes[old] = nil
        }
    }

    /// A finished agent that acts again (teammates can be resumed) is live again.
    private func revive(_ id: String) {
        guard let n = nodes[id] else { return }
        switch n.state {
        case .done, .error:
            finished.removeAll { $0 == id }
            nodes[id]!.finishedAt = nil
        default: break
        }
    }

    private func update(_ id: String, at t: Date?, _ change: (inout AgentNode) -> Void) {
        guard var n = nodes[id] else { return }
        change(&n)
        n.activity = Self.oneLine(n.activity)
        switch n.state {
        case .needsInput(let s): n.state = .needsInput(Self.oneLine(s))
        case .error(let s): n.state = .error(Self.oneLine(s))
        default: break
        }
        if case .needsInput = n.state {} else { n.resumeState = nil }
        if let t { n.updatedAt = max(n.updatedAt, t) }
        if n != nodes[id] { nodes[id] = n }
    }

    private static func isReport(_ e: AgentEvent) -> Bool {
        e.tool == "SubagentHandback"
            || (e.tool == "SendMessage" && ["team-lead", "main", "lead", "orchestrator"].contains((e.to ?? "").lowercased()))
    }

    private static func isBusyOrStuck(_ s: AgentState) -> Bool {
        switch s {
        case .done: return false
        default: return true
        }
    }

    /// Sets needsInput and remembers a `ca wait` it interrupts. A generic notification
    /// never replaces a more specific ask (like the PermissionRequest's "Needs
    /// permission: Running x"); a `specific` one does.
    private static func ask(_ n: inout AgentNode, _ text: String, specific: Bool = false) {
        if case .needsInput = n.state {
            guard specific else { return }
        } else if case .waiting = n.state {
            n.resumeState = n.state
        } else {
            n.resumeState = nil
        }
        n.state = .needsInput(text)
        n.activity = text
    }

    /// One line of plain text from markdown: first non-empty line, no `**`, backticks,
    /// heading marks or list bullets, whitespace collapsed.
    nonisolated static func oneLine(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let s = plain(String(line))
            if !s.isEmpty { return s }
        }
        return ""
    }

    nonisolated private static func plain(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") || s.hasPrefix("* ") { s.removeFirst(2) }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func push(_ text: String, into recent: inout [String]) {
        let line = text.split(whereSeparator: \.isNewline).map { plain(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return }
        let l = line.count > 160 ? String(line.prefix(157)) + "..." : line
        if recent.last == l { return }
        recent.append(l)
        if recent.count > keepRecent { recent.removeFirst(recent.count - keepRecent) }
    }
}
