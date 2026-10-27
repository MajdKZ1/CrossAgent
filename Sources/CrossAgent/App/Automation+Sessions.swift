import Foundation

/// Session commands, so discovery, the Live view and Continue here can be tested
/// without clicking.
///
///     {"cmd":"sessions","out":"/tmp/s.json"}                   polls every host, writes what discovery sees
///     {"cmd":"openSession","host":"mac","sessionId":"..."}     same as a row click
///     {"cmd":"openLive","host":"mac","sessionId":"..."}        the Live view even for a tmux session
///     {"cmd":"continueSession","host":"pc","sessionId":"...","confirm":true}
///                                                              Continue here; confirm is "I've closed it"
///     {"cmd":"orchPick","id":"mac:<sessionId>"}                Orchestrator tab shows that session (no id: back)
extension Automation {
    func handleSessions(_ name: String, _ cmd: [String: Any]) -> Bool {
        let host = cmd["host"] as? String
        let sid = cmd["sessionId"] as? String
        switch name {
        case "sessions":
            let out = cmd["out"] as? String
            Task {
                await SessionDiscovery.shared.refresh()
                if let out { try? Self.sessionsJSON().write(to: URL(fileURLWithPath: out), options: .atomic) }
            }
        case "openSession":
            guard let host, let sid else { return true }
            let app = self.app
            Task {
                let d = SessionDiscovery.shared
                if d.session(host: host, sessionId: sid) == nil { await d.refresh() }
                if let s = d.session(host: host, sessionId: sid) {
                    app?.openClaudeSession(s)
                } else {
                    app?.openClaudeLive(host: host, sessionId: sid)
                }
            }
        case "openLive":
            guard let host, let sid else { return true }
            app.openClaudeLive(host: host, sessionId: sid, title: SessionDiscovery.shared.session(host: host, sessionId: sid)?.title)
        case "continueSession":
            guard let host, let sid else { return true }
            app.continueClaudeSession(host: host, sessionId: sid, force: cmd["confirm"] as? Bool ?? false)
        case "orchPick":
            app.orchestratorSessionPick = cmd["id"] as? String
        default:
            return false
        }
        return true
    }

    static func sessionsJSON() -> Data {
        let d = SessionDiscovery.shared
        let list: [[String: Any]] = d.sessions.map { s in
            ["id": s.sessionId, "host": s.hostId, "status": s.status.rawValue, "launcher": s.launcher.rawValue,
             "title": s.title, "cwd": s.cwd, "pid": s.pid.map { Int($0) } ?? NSNull(), "tmux": s.tmuxSession ?? NSNull(),
             "subagents": s.subagentCount, "startedAt": s.startedAt.timeIntervalSince1970,
             "lastActivity": s.lastActivity.timeIntervalSince1970]
        }
        let obj: [String: Any] = ["sessions": list, "hostErrors": d.hostErrors]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Every Live view tab: what its feed holds and its agents' states.
    func liveViewsJSON() -> [[String: Any]] {
        app.tabs.compactMap { t -> [String: Any]? in
            guard case .agent(.claude(let h, let sid)) = t.kind else { return nil }
            let feed = SessionFeed.feed(host: h, sessionId: sid)
            let last = feed.items.last
            let nodes: [[String: Any]] = feed.graph.nodes.values.sorted { $0.startedAt < $1.startedAt }.map { n in
                ["id": n.id, "name": n.name, "kind": n.kind.rawValue, "state": Self.stateWord(n.state), "activity": n.activity]
            }
            return ["tab": t.id, "host": h, "sessionId": sid, "title": app.title(of: t), "status": feed.status.rawValue,
                    "items": feed.items.count, "subagentItems": feed.items.filter { $0.agentId != nil }.count,
                    "lastKind": last?.kind.rawValue ?? NSNull(), "lastText": last.map { String($0.text.prefix(200)) } ?? NSNull(),
                    "blocker": app.continueBlocker(host: h, sessionId: sid, feedStatus: feed.status) ?? NSNull(),
                    "nodes": nodes]
        }
    }

    static func stateWord(_ s: AgentState) -> String {
        switch s {
        case .thinking: "thinking"
        case .working: "working"
        case .needsInput: "needsInput"
        case .waiting: "waiting"
        case .idle: "idle"
        case .done: "done"
        case .error: "error"
        }
    }
}
