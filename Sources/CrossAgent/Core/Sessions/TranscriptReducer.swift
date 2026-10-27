import Foundation

/// Builds `AgentGraph` state from a session's transcript items, its subagent metas and
/// its live status, so a session CrossAgent didn't start draws like a hooked one.
/// Deterministic: time comes from the items and from `tick(now:)`.
///
/// Subagent nodes are keyed by the Agent call's tool_use id, the one thing every flavor
/// shows first. Agent ids (subagent file names) map onto it once known, from the Agent
/// result, a task notification or the meta's toolUseId.
@MainActor
final class TranscriptReducer {
    let graph: AgentGraph
    private var nodeForAgent: [String: String] = [:]
    /// Live status from the session file. Nil when not known (ended or not read yet):
    /// the orchestrator state then follows the transcript alone.
    private(set) var liveStatus: ClaudeSessionStatus?
    private var waitingFor: String?
    /// The orchestrator's state as the transcript alone says.
    private var transcriptState: AgentState = .idle
    /// The project slug, when known, so a `ca remote` link can name its tmux session early.
    var slug: String?

    init(graph: AgentGraph) {
        self.graph = graph
    }

    func apply(_ items: [TranscriptItem]) {
        for i in items { apply(i) }
        settleOrchestrator(at: nil)
    }

    func apply(_ item: TranscriptItem) {
        if let aid = item.agentId {
            applySubagentItem(aid, item)
        } else {
            applyMainItem(item)
        }
        if let s = item.signal { applySignal(s, item) }
    }

    /// A subagent's meta.json, read when it appears or changes.
    func apply(meta: SubagentMeta, agentId: String, at t: Date) {
        if let tuid = meta.toolUseId { link(agentId: agentId, toolUseId: tuid) }
        let id = nodeId(agentId: agentId, name: meta.displayName, at: t)
        update(id, at: nil) {
            if $0.name == "agent" || $0.name == meta.agentType { $0.name = meta.displayName }
        }
        if meta.finished == true { finish(id, at: t, ok: true, message: nil) }
    }

    /// The session file's status. `nil` once the session has no process.
    func applyStatus(_ status: ClaudeSessionStatus?, waitingFor: String?, at t: Date) {
        liveStatus = status == .ended ? nil : status
        self.waitingFor = waitingFor
        if status == .ended || status == nil {
            if transcriptState != .idle { transcriptState = .idle }
            update(AgentGraph.orchestratorID, at: t) { n in
                if case .error = n.state { return }
                n.state = .idle
                n.activity = "Session ended"
            }
            return
        }
        settleOrchestrator(at: t)
    }

    /// Busy subagents quiet for `AgentGraph.idleAfter` go idle. Same rule as hooks.
    func tick(now: Date) { graph.tick(now: now) }

    /// The graph node an agent id's lines belong to, if any yet.
    func node(forAgent agentId: String) -> String? {
        nodeForAgent[agentId].flatMap { graph.nodes[$0] != nil ? $0 : nil }
    }

    // MARK: Orchestrator

    private func applyMainItem(_ item: TranscriptItem) {
        let o = AgentGraph.orchestratorID
        let t = item.at
        switch item.kind {
        case .user:
            transcriptState = .thinking
            update(o, at: t) { $0.activity = item.text }
        case .thinking:
            transcriptState = .thinking
            update(o, at: t) { _ in }
        case .toolUse:
            transcriptState = .working
            update(o, at: t) {
                $0.activity = item.text
                Self.push(item.text, into: &$0.recent)
            }
            if item.tool == "SendMessage" { flowToNamed(item, t) }
            linkRemote(item, to: o)
        case .toolResult:
            transcriptState = .working
            update(o, at: t) { _ in }
        case .assistant:
            update(o, at: t) {
                $0.activity = item.text
                Self.push(item.text, into: &$0.recent)
            }
        case .system:
            if item.isError {
                update(o, at: t) { $0.activity = item.text }
            }
        }
        settleOrchestrator(at: t)
    }

    /// Final orchestrator state: the live status when there is one, else the transcript.
    private func settleOrchestrator(at t: Date?) {
        let o = AgentGraph.orchestratorID
        let live = liveSubagents()
        let state: AgentState
        switch liveStatus {
        case .waiting?:
            let what = waitingFor == "permission prompt" ? "Needs permission" : "Needs your input"
            state = .needsInput(what)
        case .running?:
            state = transcriptState == .thinking ? .thinking : .working
        case .idle?:
            state = live.isEmpty ? .idle : .waiting(live)
        case .ended?, nil:
            state = transcriptState == .idle && !live.isEmpty ? .waiting(live) : transcriptState
        }
        update(o, at: t) { n in
            if n.state == state { return }
            if case .needsInput = state {
                n.activity = Self.needsText(state)
            } else if case .waiting(let names) = state {
                n.activity = "Waiting on " + names.joined(separator: ", ")
            } else if case .needsInput = n.state {
                n.activity = n.recent.last ?? "Working"
            }
            n.state = state
        }
    }

    private static func needsText(_ s: AgentState) -> String {
        if case .needsInput(let t) = s { return t }
        return ""
    }

    private func liveSubagents() -> [String] {
        graph.others.filter { n in
            switch n.state {
            case .done, .error: return false
            default: return n.kind == .subagent
            }
        }.map(\.name)
    }

    // MARK: Subagents

    private func applySignal(_ s: AgentSignal, _ item: TranscriptItem) {
        let t = item.at
        switch s {
        case .spawn(let name, let prompt):
            guard let tuid = item.toolUseId else { return }
            if graph.nodes[tuid] == nil {
                graph.nodes[tuid] = AgentNode(id: tuid, name: name, kind: .subagent, hostId: graph.orchestratorHost,
                                              state: .thinking, activity: "Starting", prompt: prompt.map { String($0.prefix(600)) },
                                              startedAt: t, updatedAt: t, flow: .toNode, flowAt: t)
            }
            flow(AgentGraph.orchestratorID, .toNode, t)
        case .launched(let aid):
            if let tuid = item.toolUseId { link(agentId: aid, toolUseId: tuid) }
        case .finished(let aid, let ok, let result):
            if let aid, let tuid = item.toolUseId { link(agentId: aid, toolUseId: tuid) }
            let id = item.toolUseId.flatMap { graph.nodes[$0] != nil ? $0 : nil }
                ?? aid.flatMap { nodeForAgent[$0] }
            guard let id, graph.nodes[id] != nil else { return }
            finish(id, at: t, ok: ok, message: ok ? result : (result ?? "Failed"))
        case .message(let from, let text):
            guard let id = node(named: from) else { return }
            revive(id, at: t)
            update(id, at: t) {
                $0.activity = text
                Self.push(text, into: &$0.recent)
                $0.flow = .toOrchestrator
                $0.flowAt = t
            }
        case .teammateIdle(let name, let result):
            guard let id = node(named: name) else { return }
            finish(id, at: t, ok: true, message: result)
        }
        settleOrchestrator(at: t)
    }

    private func applySubagentItem(_ aid: String, _ item: TranscriptItem) {
        let t = item.at
        let id = nodeId(agentId: aid, name: nil, at: t)
        // Lines older than its finish are history, not a sign of life.
        if let f = graph.nodes[id]?.finishedAt, t <= f { return }
        revive(id, at: t)
        switch item.kind {
        case .toolUse:
            update(id, at: t) {
                $0.state = .working
                $0.activity = item.text
                Self.push(item.text, into: &$0.recent)
            }
            if item.tool == "SendMessage" || item.tool == "SubagentHandback" { flow(id, .toOrchestrator, t) }
            linkRemote(item, to: id)
        case .toolResult:
            update(id, at: t) { $0.state = item.isError ? $0.state : .working }
        case .assistant:
            update(id, at: t) {
                $0.state = .working
                $0.activity = item.text
                Self.push(item.text, into: &$0.recent)
            }
        case .thinking:
            update(id, at: t) { $0.state = .thinking }
        case .user:
            update(id, at: t) { n in if n.prompt == nil { n.prompt = String(item.text.prefix(600)) } }
        case .system:
            break
        }
    }

    /// A Bash call running `ca remote` makes its node the worker's node.
    private func linkRemote(_ item: TranscriptItem, to id: String) {
        guard item.tool == "Bash" else { return }
        let command = item.command ?? (item.text.hasPrefix("Running ") ? String(item.text.dropFirst(8)) : item.text)
        for r in graph.caRemoteTargets(command) {
            graph.linkRemote(nodeID: id, host: r.host, role: r.role, slug: slug, at: item.at)
        }
    }

    /// The node for an agent id, made from what's known when nothing links it yet.
    private func nodeId(agentId: String, name: String?, at t: Date) -> String {
        if let id = nodeForAgent[agentId], graph.nodes[id] != nil { return id }
        if graph.nodes[agentId] == nil {
            graph.nodes[agentId] = AgentNode(id: agentId, name: name ?? "agent", kind: .subagent,
                                             hostId: graph.orchestratorHost, state: .thinking,
                                             activity: "Starting", startedAt: t, updatedAt: t, flow: .toNode, flowAt: t)
        }
        nodeForAgent[agentId] = agentId
        return agentId
    }

    /// Ties an agent id to its Agent call. A node made early under the agent id folds
    /// into the call's node.
    private func link(agentId: String, toolUseId: String) {
        guard nodeForAgent[agentId] != toolUseId else { return }
        nodeForAgent[agentId] = toolUseId
        guard let early = graph.nodes[agentId], agentId != toolUseId else { return }
        if var n = graph.nodes[toolUseId] {
            for r in early.recent { Self.push(r, into: &n.recent) }
            if early.updatedAt > n.updatedAt {
                n.state = early.state
                n.activity = early.activity
                n.updatedAt = early.updatedAt
                n.finishedAt = early.finishedAt
            }
            if n.prompt == nil { n.prompt = early.prompt }
            if n.remote == nil, let r = early.remote {
                n.remote = r
                n.hostId = early.hostId
            }
            graph.nodes[toolUseId] = n
        } else {
            var n = early
            n.id = toolUseId
            graph.nodes[toolUseId] = n
        }
        graph.nodes[agentId] = nil
        if let i = graph.finished.firstIndex(of: agentId) { graph.finished[i] = toolUseId }
        graph.remoteNodeRenamed(from: agentId, to: toolUseId)
    }

    private func node(named name: String) -> String? {
        graph.others.last { $0.kind == .subagent && $0.name == name }?.id
    }

    private func flowToNamed(_ item: TranscriptItem, _ t: Date) {
        // "Messaging sleeper: ..." names the target.
        guard item.text.hasPrefix("Messaging ") else { return }
        let rest = item.text.dropFirst("Messaging ".count)
        let to = String(rest.split(separator: ":").first ?? rest)
        if let id = node(named: to) { flow(id, .toNode, t) }
    }

    // MARK: Helpers

    private func finish(_ id: String, at t: Date, ok: Bool, message: String?) {
        guard let n = graph.nodes[id] else { return }
        if ok, n.state == .done { return }
        if !ok, case .error = n.state { return }
        update(id, at: t) {
            if ok {
                $0.state = .done
                if let m = message, !AgentGraph.oneLine(m).isEmpty {
                    $0.activity = m
                    Self.push(m, into: &$0.recent)
                } else if $0.activity.isEmpty || $0.activity == "Starting" {
                    $0.activity = "Done"
                }
            } else {
                let m = message ?? "Failed"
                $0.state = .error(m)
                $0.activity = m
            }
            $0.flow = .toOrchestrator
            $0.flowAt = t
            $0.finishedAt = t
        }
        graph.finished.removeAll { $0 == id }
        graph.finished.append(id)
        while graph.finished.count > AgentGraph.keepFinished {
            let old = graph.finished.removeFirst()
            graph.nodes[old] = nil
        }
        graph.remoteNodeFinished(id)
    }

    /// A finished teammate that acts again is live again.
    private func revive(_ id: String, at t: Date) {
        guard let n = graph.nodes[id] else { return }
        switch n.state {
        case .done, .error:
            if let f = n.finishedAt, t <= f { return }
            graph.finished.removeAll { $0 == id }
            graph.nodes[id]!.finishedAt = nil
            graph.nodes[id]!.state = .working
        default: break
        }
    }

    private func flow(_ id: String, _ f: CableFlow, _ t: Date) {
        guard graph.nodes[id] != nil else { return }
        graph.nodes[id]!.flow = f
        graph.nodes[id]!.flowAt = t
    }

    private func update(_ id: String, at t: Date?, _ change: (inout AgentNode) -> Void) {
        guard var n = graph.nodes[id] else { return }
        change(&n)
        AgentGraph.holdRemotePermission(&n)
        n.activity = AgentGraph.oneLine(n.activity)
        switch n.state {
        case .needsInput(let s): n.state = .needsInput(AgentGraph.oneLine(s))
        case .error(let s): n.state = .error(AgentGraph.oneLine(s))
        default: break
        }
        if let t { n.updatedAt = max(n.updatedAt, t) }
        if n != graph.nodes[id] { graph.nodes[id] = n }
    }

    private static func push(_ text: String, into recent: inout [String]) {
        let line = text.split(whereSeparator: \.isNewline).map { AgentGraph.oneLine(String($0)) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return }
        let l = line.count > 160 ? String(line.prefix(157)) + "..." : line
        if recent.last == l { return }
        recent.append(l)
        if recent.count > AgentGraph.keepRecent { recent.removeFirst(recent.count - AgentGraph.keepRecent) }
    }
}
