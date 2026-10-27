import Foundation

/// The tabs on a remote worker's card.
enum RemoteCardTab: String, CaseIterable {
    case terminal, brief, result

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .brief: "Brief"
        case .result: "Result"
        }
    }
}

/// A remote worker's brief.md or result.md as last read from its host.
struct RemoteDoc: Equatable {
    /// What it was read for (path, turn, running), so a change reads it again.
    var key: String
    var loading = true
    /// Nil until read, or when the file isn't there yet.
    var text: String?
    var error: String?

    static func slot(_ nodeID: String, _ tab: RemoteCardTab) -> String { nodeID + "/" + tab.rawValue }
}

enum PermissionSend: Equatable {
    case sending
    /// Written, the card goes once the worker's PermissionAnswer event lands.
    case sent(allow: Bool)
}

extension AppState {
    /// Request ids name a file on the worker's host, so only this shape gets through.
    nonisolated static func validPermissionID(_ id: String) -> Bool {
        id.range(of: "^[a-f0-9]{12}$", options: .regularExpression) != nil
    }

    /// Nodes waiting on an approval, oldest first.
    var pendingPermissions: [AgentNode] {
        guard let g = orch?.shown else { return [] }
        return g.nodes.values.filter { $0.remote?.permission != nil }
            .sorted { ($0.remote?.permission?.at ?? .distantPast) < ($1.remote?.permission?.at ?? .distantPast) }
    }

    // MARK: Tabs

    func remoteTab(_ nodeID: String) -> RemoteCardTab { orch?.remoteTabs[nodeID] ?? .terminal }

    /// Switches a remote card's tab. The keyboard follows: the terminal gets it back,
    /// the text tabs take it away.
    func setRemoteTab(_ nodeID: String, _ tab: RemoteCardTab) {
        guard let o = orch, o.remoteTabs[nodeID] != tab else { return }
        o.remoteTabs[nodeID] = tab
        DispatchQueue.main.async { [weak self] in self?.focusSelectedTab() }
    }

    /// Opens a node's card, on `tab` for remote workers.
    func openNode(_ id: String, tab: RemoteCardTab?) {
        if let tab, orch?.shown.nodes[id]?.remote != nil { orch?.remoteTabs[id] = tab }
        expandNode(id)
    }

    /// Attaches the card's terminal to the worker's tmux session on its host, the first
    /// time the Terminal tab shows. Never creates the session. Closed with the tab.
    func attachRemotePane(tabID: String, node: AgentNode) {
        guard agentPanes[tabID] == nil, let r = node.remote, let host = host(r.host),
              let pane = attachPane(host: host, session: r.tmuxSession) else { return }
        agentPanes[tabID] = pane
        if selectedTabID == tabID { DispatchQueue.main.async { [weak self] in self?.focusSelectedTab() } }
    }

    /// The terminal of a remote worker's open card, if it attached one.
    func remoteCardPane(_ nodeID: String) -> PaneSession? {
        guard let tab = tabs.first(where: { $0.kind == .agent(.node(nodeID)) }) else { return nil }
        return agentPanes[tab.id]
    }

    // MARK: Brief and result

    /// Reads the brief or result off the worker's host, unless it was already read for `key`.
    func loadRemoteDoc(node: AgentNode, tab: RemoteCardTab, key: String) async {
        guard let o = orch, let r = node.remote, tab != .terminal else { return }
        let slot = RemoteDoc.slot(node.id, tab)
        if let d = o.remoteDocs[slot], d.key == key, d.error == nil { return }
        guard let path = tab == .brief ? r.briefPath : r.resultPath, path.hasPrefix("/") else {
            o.remoteDocs[slot] = RemoteDoc(key: key, loading: false)
            return
        }
        guard let host = host(r.host) else {
            o.remoteDocs[slot] = RemoteDoc(key: key, loading: false, error: "Unknown host \(r.host)")
            return
        }
        // Keep the old text up while the new one loads, so a reload doesn't flash.
        var doc = o.remoteDocs[slot] ?? RemoteDoc(key: key)
        doc.key = key
        doc.loading = true
        o.remoteDocs[slot] = doc
        let result = await Self.readFile(path, on: host)
        guard orch === o, o.remoteDocs[slot]?.key == key else { return }
        doc.loading = false
        switch result {
        case .success(let text): doc.text = text; doc.error = nil
        case .failure(let e): doc.error = e.message
        }
        o.remoteDocs[slot] = doc
    }

    struct ReadError: Error { var message: String }

    /// Up to 256 KB of a text file on a host. Missing gives nil text, not an error.
    nonisolated static let docLimit = 256 * 1024

    nonisolated static func readFile(_ path: String, on host: Host) async -> Result<String?, ReadError> {
        if host.isLocal {
            return await Task.detached(priority: .userInitiated) { () -> Result<String?, ReadError> in
                guard let h = FileHandle(forReadingAtPath: path) else { return .success(nil) }
                defer { try? h.close() }
                let data = (try? h.read(upToCount: docLimit)) ?? Data()
                return .success(String(decoding: data, as: UTF8.self))
            }.value
        }
        let p = CommandBuilder.shellQuote(path)
        let script = "test -f \(p) || exit 3; head -c \(docLimit) -- \(p)"
        let r = await Runner.run(CommandBuilder.oneShot(host: host, script: script), timeout: 30)
        switch r.status {
        case 0: return .success(r.stdout)
        case 3: return .success(nil)
        default:
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(ReadError(message: err.isEmpty ? "Couldn't reach \(host.name)" : err))
        }
    }

    // MARK: Approvals

    /// Answers a remote worker's permission prompt: writes allow or deny to
    /// ~/.crossagent/approvals/<id>.answer on the worker's host, where its permission
    /// tool is waiting. The card clears when the PermissionAnswer event comes back.
    func answerPermission(nodeID: String, allow: Bool) {
        guard let o = orch, let ask = o.shown.nodes[nodeID]?.remote?.permission else { return }
        guard Self.validPermissionID(ask.id) else {
            flash("That approval has a bad id")
            return
        }
        guard o.permissionSends[ask.id] != .sending else { return }
        guard let host = host(ask.host) else {
            flash("Unknown host \(ask.host)")
            return
        }
        // Written to a temp name and moved, so the waiting tool never reads half a file.
        let word = allow ? "allow" : "deny"
        let dir = "\"$HOME/.crossagent/approvals\""
        // Only while the request is still waiting, so a late answer leaves no file behind.
        let script = "test -f \(dir)/\(ask.id).json || { echo 'that request already timed out' >&2; exit 1; }"
            + " && printf \(word) > \(dir)/\(ask.id).answer.tmp"
            + " && mv -f \(dir)/\(ask.id).answer.tmp \(dir)/\(ask.id).answer"
        o.permissionSends[ask.id] = .sending
        // Answers for prompts that are gone by now.
        let live = Set(o.shown.nodes.values.compactMap { $0.remote?.permission?.id })
        for id in o.permissionSends.keys where !live.contains(id) { o.permissionSends[id] = nil }
        Task { [weak self] in
            let r = await Runner.run(CommandBuilder.oneShot(host: host, script: script), timeout: 30)
            guard let self, self.orch === o else { return }
            if r.status == 0 {
                o.permissionSends[ask.id] = .sent(allow: allow)
            } else {
                o.permissionSends[ask.id] = nil
                let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                self.flash("Couldn't send the answer" + (err.isEmpty ? "" : ": " + String(err.prefix(80))))
            }
        }
    }
}
