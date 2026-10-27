#if DEBUG
import Foundation

/// Remote worker commands, so cards, docs and approvals can be checked without clicking.
///
///     {"cmd":"nodes","out":"/tmp/n.json"}                        every node with its remote info, approval and card state
///     {"cmd":"openNode","id":"<node>","tab":"brief"}             opens its card; tab is terminal, brief or result
///     {"cmd":"answer","id":"<node>","permission":"allow"}        Allow (or "deny") on its approval card
///     {"cmd":"setRemote","id":"n1","name":"pc-tests","kind":"subagent","host":"pc","role":"tests",
///      "tmux":"ca-x-pc-tests","turn":1,"brief":"/abs/brief.md","result":"/abs/result.md",
///      "permission":{"id":"0123456789ab","text":"Needs permission: Running npm test","detail":"npm test"}}
///                                                                sets a node's remote info straight in the shown graph,
///                                                                making the node if needed ("permission":null clears it)
extension Automation {
    func handleRemote(_ name: String, _ cmd: [String: Any]) -> Bool {
        switch name {
        case "nodes":
            if let out = cmd["out"] as? String {
                let obj: [String: Any] = ["nodes": nodesJSON(), "pending": app.pendingPermissions.map(\.id), "toast": app.toast ?? ""]
                let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                try? data.write(to: URL(fileURLWithPath: out), options: .atomic)
            }
        case "openNode":
            guard let id = cmd["id"] as? String else { return true }
            app.openNode(id, tab: (cmd["tab"] as? String).flatMap(RemoteCardTab.init(rawValue:)))
        case "answer" where cmd["permission"] != nil:
            guard let id = cmd["id"] as? String, let word = cmd["permission"] as? String,
                  word == "allow" || word == "deny" else { return true }
            app.answerPermission(nodeID: id, allow: word == "allow")
        case "setRemote":
            setRemote(cmd)
        default:
            return false
        }
        return true
    }

    private func setRemote(_ cmd: [String: Any]) {
        guard let g = app.orch?.shown, let id = cmd["id"] as? String else { return }
        let now = Date()
        let host = cmd["host"] as? String ?? "pc"
        var n = g.nodes[id] ?? AgentNode(id: id, name: cmd["name"] as? String ?? id,
                                          kind: AgentKind(rawValue: cmd["kind"] as? String ?? "subagent") ?? .subagent,
                                          hostId: host, state: .working, activity: "Working",
                                          startedAt: now, updatedAt: now)
        var r = n.remote ?? RemoteInfo(host: host, role: cmd["role"] as? String ?? id,
                                       tmuxSession: cmd["tmux"] as? String ?? "ca-x-\(host)-\(id)")
        if let v = cmd["turn"] as? Int { r.turn = v }
        if let v = cmd["brief"] as? String { r.briefPath = v }
        if let v = cmd["result"] as? String { r.resultPath = v }
        if let v = cmd["tmux"] as? String { r.tmuxSession = v }
        if cmd["permission"] is NSNull {
            r.permission = nil
        } else if let p = cmd["permission"] as? [String: Any], let pid = p["id"] as? String {
            r.permission = PermissionAsk(id: pid, host: p["host"] as? String ?? r.host,
                                         text: p["text"] as? String ?? "Needs permission", detail: p["detail"] as? String, at: now)
        }
        if let s = cmd["state"] as? String {
            switch s {
            case "working": n.state = .working
            case "idle": n.state = .idle
            case "done": n.state = .done
            default: break
            }
        }
        n.remote = r
        n.updatedAt = now
        g.nodes[id] = n
    }

    private func nodesJSON() -> [[String: Any]] {
        guard let o = app.orch else { return [] }
        return o.shown.nodes.values.sorted { $0.startedAt < $1.startedAt }.map { n in
            var row: [String: Any] = ["id": n.id, "name": n.name, "kind": n.kind.rawValue, "host": n.hostId,
                                      "state": Self.stateWord(n.state), "activity": n.activity,
                                      "session": n.tmuxSession ?? NSNull()]
            guard let r = n.remote else {
                row["remote"] = NSNull()
                return row
            }
            var remote: [String: Any] = ["host": r.host, "role": r.role, "tmuxSession": r.tmuxSession,
                                         "claudeSession": r.claudeSession ?? NSNull(), "turn": r.turn,
                                         "briefPath": r.briefPath ?? NSNull(), "resultPath": r.resultPath ?? NSNull(),
                                         "permission": NSNull()]
            if let p = r.permission {
                var send: Any = NSNull()
                switch o.permissionSends[p.id] {
                case .sending: send = "sending"
                case .sent(let allow): send = allow ? "allow" : "deny"
                case nil: break
                }
                remote["permission"] = ["id": p.id, "host": p.host, "text": p.text, "detail": p.detail ?? NSNull(),
                                        "at": p.at.timeIntervalSince1970, "send": send] as [String: Any]
            }
            row["remote"] = remote
            var card: [String: Any] = ["tab": app.remoteTab(n.id).rawValue]
            if let t = app.tabs.first(where: { $0.kind == .agent(.node(n.id)) }) {
                card["open"] = true
                card["selected"] = t.id == app.selectedTabID
                if let p = app.agentPanes[t.id] {
                    card["terminal"] = p.isLive ? "live" : (p.isExited ? "exited" : "connecting")
                    card["screen"] = p.screenText()
                }
            } else {
                card["open"] = false
            }
            for tab in [RemoteCardTab.brief, .result] {
                guard let d = o.remoteDocs[RemoteDoc.slot(n.id, tab)] else { continue }
                card[tab.rawValue] = ["loading": d.loading, "text": d.text ?? NSNull(), "error": d.error ?? NSNull(),
                                      "key": d.key] as [String: Any]
            }
            row["card"] = card
            return row
        }
    }
}
#endif
