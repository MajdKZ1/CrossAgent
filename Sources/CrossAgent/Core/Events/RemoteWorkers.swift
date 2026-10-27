import Foundation

/// A `ca remote` target: the worker `role` on `host`.
struct RemoteTarget: Equatable {
    var host: String
    var role: String
}

/// Remote worker bookkeeping kept with the graph. Keys are "host/role".
struct RemoteTable: Equatable {
    /// The node that shows a worker: the pc-worker subagent that runs it.
    var links: [String: String] = [:]
    /// Workers whose turn is running: RemoteStart seen, no RemoteStop yet.
    var running: Set<String> = []
    /// Workers the orchestrator drives itself, so their RemoteStop finishes the node.
    var direct: Set<String> = []
    /// Old proxies a newer one took the worker from, removed once they finish.
    var retired: Set<String> = []
    /// Finished proxies a new turn woke up before the new proxy's link came in.
    var revived: Set<String> = []
}

/// One node per remote worker, for both graph sources (hooks and transcripts).
///
/// A worker started through a `pc-worker` subagent draws as that subagent's node, which
/// gets `remote` and the worker's host. Remote events and the subagent's `ca remote`
/// call come from different machines, so either can arrive first: events with no link
/// yet make a standalone `.worker` node (id = the tmux session) that folds into the
/// subagent once the link shows up.
extension AgentGraph {
    nonisolated static func remoteKey(host: String, role: String) -> String { host + "/" + role }

    /// The node showing a worker: the linked one, else a standalone node.
    func remoteNode(host: String, role: String) -> String? {
        if let id = remoteTable.links[Self.remoteKey(host: host, role: role)], nodes[id] != nil { return id }
        return nodes.values.first { $0.kind == .worker && $0.remote?.host == host && $0.remote?.role == role }?.id
    }

    /// True while the node's remote turn runs. Test suites on the PC can be quiet for minutes.
    func isRemoteRunning(_ id: String) -> Bool {
        guard let r = nodes[id]?.remote else { return false }
        return remoteTable.running.contains(Self.remoteKey(host: r.host, role: r.role))
    }

    /// Applies one role "remote" event.
    func applyRemote(_ e: AgentEvent, at t: Date) {
        guard let role = e.node, !role.isEmpty else { return }
        let host = e.host ?? "pc"
        let key = Self.remoteKey(host: host, role: role)
        let tmux = e.tmux ?? e.sid ?? CASessionName.make(slug: e.project ?? "", host: host, task: role)
        let id: String
        if let n = remoteNode(host: host, role: role) {
            id = n
        } else {
            id = tmux
            nodes[id] = AgentNode(id: id, name: role, kind: .worker, hostId: host, state: .working, activity: "Starting",
                                  tmuxSession: tmux, startedAt: t, updatedAt: t, flow: .toNode, flowAt: t)
        }
        update(id, at: nil) {
            if $0.remote == nil { $0.remote = RemoteInfo(host: host, role: role, tmuxSession: tmux) }
            if $0.remote!.tmuxSession.isEmpty { $0.remote!.tmuxSession = tmux }
            $0.hostId = host
        }
        let sum = e.sum.flatMap { Self.oneLine($0).isEmpty ? nil : $0 }
        switch e.ev {
        case "RemoteStart":
            remoteTable.running.insert(key)
            wake(id, key)
            let turn = e.turn ?? (nodes[id]!.remote!.turn + 1)
            update(id, at: t) {
                $0.state = .working
                $0.activity = sum ?? (turn > 1 ? "Starting turn \(turn)" : "Starting")
                if let s = sum { Self.push(s, into: &$0.recent) }
                $0.remote!.turn = turn
                $0.remote!.briefPath = e.path ?? $0.remote!.briefPath
                $0.remote!.claudeSession = e.csid ?? $0.remote!.claudeSession
                $0.remote!.resultPath = nil
                $0.remote!.permission = nil
                $0.flow = .toNode
                $0.flowAt = t
            }
        case "RemoteActivity":
            guard let s = sum else { return }
            if let n = nodes[id], Self.isOver(n.state) {
                guard remoteTable.running.contains(key) else { return }
                wake(id, key)
            }
            update(id, at: t) {
                Self.push(s, into: &$0.recent)
                if $0.remote?.permission != nil { return }
                $0.state = .working
                $0.activity = s
            }
        case "PermissionAsk":
            guard let req = e.req, !req.isEmpty else { return }
            let text = sum ?? "Needs permission"
            update(id, at: t) {
                $0.remote!.permission = PermissionAsk(id: req, host: host, text: text, detail: e.prompt, at: t)
                Self.ask(&$0, text, specific: true)
            }
        case "PermissionAnswer":
            guard let p = nodes[id]?.remote?.permission, e.req == nil || e.req == p.id else { return }
            let prefix = "Needs permission: "
            let what = p.text.hasPrefix(prefix) ? String(p.text.dropFirst(prefix.count)) : p.text
            let text: String
            switch e.msg {
            case "allow": text = "Allowed: " + what
            case "deny": text = "Denied: " + what
            default: text = "No answer, denied"
            }
            update(id, at: t) {
                $0.remote!.permission = nil
                if case .needsInput = $0.state { $0.state = .working }
                $0.activity = text
                Self.push(text, into: &$0.recent)
            }
        case "RemoteStop":
            remoteTable.running.remove(key)
            let rc = e.rc ?? 0
            update(id, at: t) {
                $0.remote!.resultPath = e.path ?? $0.remote!.resultPath
                $0.remote!.claudeSession = e.csid ?? $0.remote!.claudeSession
                if let turn = e.turn { $0.remote!.turn = turn }
                $0.remote!.permission = nil
                if case .needsInput = $0.state { $0.state = .working }
                if let s = sum { Self.push(s, into: &$0.recent) }
            }
            let proxied = nodes[id]?.kind == .subagent && !remoteTable.direct.contains(key) && !remoteTable.revived.contains(id)
            if !proxied {
                if rc == 0 { finish(id, at: t, message: sum ?? "Done") } else { fail(id, at: t, rc: rc, message: sum) }
            } else if let n = nodes[id], !Self.isOver(n.state) {
                // The pc-worker subagent still has to hand the result back; its SubagentStop finishes it.
                update(id, at: t) {
                    $0.state = .working
                    $0.activity = "Reporting back: " + (sum ?? (rc == 0 ? "done" : "exit \(rc)"))
                    $0.flow = .toOrchestrator
                    $0.flowAt = t
                }
            }
        default:
            break
        }
    }

    /// A finished node gets going again. A proxy whose own run is over is marked, so the
    /// turn's RemoteStop finishes it and a newer proxy's link drops it.
    private func wake(_ id: String, _ key: String) {
        guard let n = nodes[id], Self.isOver(n.state) else { return }
        if n.kind == .subagent, !remoteTable.direct.contains(key) { remoteTable.revived.insert(id) }
        revive(id)
    }

    /// `nodeID` ran `ca remote <host> <role>` (or `ca remote wait`). A subagent becomes the
    /// worker's node: a standalone node or an older proxy folds into it. The orchestrator
    /// (`orchestratorID`) driving a worker itself links nothing, its standalone node stays.
    /// `slug` names the tmux session before any event does; nil when not known.
    func linkRemote(nodeID: String, host: String, role: String, slug: String?, at t: Date) {
        let key = Self.remoteKey(host: host, role: role)
        if nodeID == Self.orchestratorID {
            remoteTable.direct.insert(key)
            return
        }
        guard var n = nodes[nodeID] else { return }
        remoteTable.direct.remove(key)
        let current = remoteNode(host: host, role: role)
        remoteTable.links[key] = nodeID
        var info = n.remote.flatMap { $0.host == host && $0.role == role ? $0 : nil }
        if let c = current, c != nodeID, let other = nodes[c] {
            if info == nil { info = other.remote }
            for r in other.recent { Self.push(r, into: &n.recent) }
            let running = remoteTable.running.contains(key)
            if !Self.isOver(n.state), other.remote?.permission != nil || (running && other.updatedAt >= n.updatedAt) {
                n.state = other.state
                n.activity = other.activity
                n.resumeState = nil
            }
            n.updatedAt = max(n.updatedAt, other.updatedAt)
            let otherDone = other.kind == .worker || other.finishedAt != nil || Self.isOver(other.state)
                || remoteTable.revived.contains(c)
            if otherDone {
                nodes[c] = nil
                finished.removeAll { $0 == c }
                remoteTable.revived.remove(c)
            } else {
                nodes[c]!.remote = nil
                nodes[c]!.hostId = orchestrator?.hostId ?? "mac"
                remoteTable.retired.insert(c)
            }
        }
        var r = info ?? RemoteInfo(host: host, role: role, tmuxSession: "")
        if r.tmuxSession.isEmpty, let s = slug, !s.isEmpty { r.tmuxSession = CASessionName.make(slug: s, host: host, task: role) }
        n.remote = r
        n.hostId = host
        nodes[nodeID] = n
        update(nodeID, at: t) { _ in }
    }

    /// A node finished: an old proxy that handed its worker on goes away now.
    func remoteNodeFinished(_ id: String) {
        remoteTable.revived.remove(id)
        guard remoteTable.retired.remove(id) != nil else { return }
        nodes[id] = nil
        finished.removeAll { $0 == id }
    }

    /// A node moved to a new id (the transcript reducer keys subagents by their Agent call).
    func remoteNodeRenamed(from old: String, to new: String) {
        for (k, v) in remoteTable.links where v == old { remoteTable.links[k] = new }
        if remoteTable.retired.remove(old) != nil { remoteTable.retired.insert(new) }
        if remoteTable.revived.remove(old) != nil { remoteTable.revived.insert(new) }
    }

    /// A pending remote permission keeps its node asking until PermissionAnswer clears it.
    static func holdRemotePermission(_ n: inout AgentNode) {
        guard let p = n.remote?.permission else { return }
        switch n.state {
        case .needsInput, .done, .error: return
        default:
            n.state = .needsInput(p.text)
            n.activity = p.text
        }
    }

    nonisolated static func isOver(_ s: AgentState) -> Bool {
        switch s {
        case .done, .error: return true
        default: return false
        }
    }

    /// `ca` host words, same as `resolve` in the skill's ca script.
    nonisolated static func remoteHost(_ word: String) -> String {
        let w = word.lowercased()
        if ["local", "mac", "macbook", "laptop", "here", "localhost"].contains(w) { return "mac" }
        if ["pc", "ssh", "overseas", "linux", "remote", "desktop", "ubuntu", "box"].contains(w) { return "pc" }
        return w
    }
}
