import Foundation

// Opening Claude Code sessions CrossAgent found but may not own: attach the ones in
// tmux, watch the rest live, and continue an ended one here in a ca-* tmux session.

extension AppState {
    // MARK: Project filter

    /// True when the session ran in this window's project folder, or inside it. On ssh
    /// hosts the folder is the project's remote copy under that user's home.
    func sessionInProject(_ s: ClaudeSession) -> Bool {
        guard let project else { return false }
        let real = Self.realPaths[project.path] ?? {
            let r = Self.realPath(project.path)
            Self.realPaths[project.path] = r
            return r
        }()
        return Self.cwd(s.cwd, isIn: project, local: host(s.hostId)?.isLocal ?? (s.hostId == "mac"), realPath: real)
    }

    private static var realPaths: [String: String] = [:]

    /// `realPath` is the project folder with symlinks resolved: Claude reports the real
    /// path, so /tmp/x runs as /private/tmp/x.
    nonisolated static func cwd(_ cwd: String, isIn project: Project, local: Bool, realPath: String? = nil) -> Bool {
        func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if local { return inside(cwd, project.path) || realPath.map { inside(cwd, $0) } == true }
        // /home/<user>/<rel>, /Users/<user>/<rel> or /root/<rel>
        let rel = cwd.replacingOccurrences(of: #"^/(home/[^/]+|Users/[^/]+|root)/?"#, with: "", options: .regularExpression)
        return rel != cwd && !project.pcRelativePath.isEmpty && inside(rel, project.pcRelativePath)
    }

    nonisolated static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// Live sessions in this project, running first.
    var projectSessions: [ClaudeSession] {
        SessionDiscovery.shared.sessions.filter { sessionInProject($0) }
    }

    // MARK: Opening

    /// A session row click. In tmux: its terminal (the grid pane if one shows it). Else
    /// the read only Live view. Deduped like any agent tab.
    func openClaudeSession(_ s: ClaudeSession) {
        switch s.openMode {
        case .attach(let t):
            guard SessionName.isAttachable(t) else { return }
            if let pane = panes.first(where: { $0.host.id == s.hostId && $0.session == t }) {
                if pane.isExited { pane.reconnect() }
                maximizedID = pane.id
                open(.panes)
                focus(pane.id)
                return
            }
            openAgent(.session(host: s.hostId, name: t))
        case .watch, .transcript:
            openClaudeLive(host: s.hostId, sessionId: s.sessionId, title: s.title)
        }
    }

    /// The Live view tab for a session, titled with its (short) title.
    func openClaudeLive(host h: String, sessionId: String, title: String? = nil) {
        let ref = AgentRef.claude(host: h, sessionId: sessionId)
        let isNew = !tabs.contains { $0.kind == .agent(ref) }
        openAgent(ref)
        guard isNew, let title, let i = tabs.firstIndex(where: { $0.kind == .agent(ref) }) else { return }
        tabs[i].title = Self.shortTitle(title)
        saveLayout()
    }

    static func shortTitle(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }

    // MARK: Continue here

    /// The tmux session a continued conversation runs in.
    func resumeSessionName(host: Host, sessionId: String) -> String? {
        guard let project else { return nil }
        let short = String(sessionId.filter { $0.isLetter || $0.isNumber }.prefix(6))
        return CASessionName.make(slug: project.slug, host: host.id, task: "resume-" + short)
    }

    /// Why Continue here is off for a session, nil when it can go ahead.
    func continueBlocker(host h: String, sessionId: String, feedStatus: ClaudeSessionStatus?) -> String? {
        let d = SessionDiscovery.shared
        let running = d.isRunning(host: h, sessionId: sessionId)
        guard running || (feedStatus != nil && feedStatus != .ended) else { return nil }
        let launcher = d.session(host: h, sessionId: sessionId)?.launcher
        let place = launcher.map { $0 == .other || $0 == .ended ? "another terminal" : $0.label } ?? "another terminal"
        return "This session is still open in \(place). Close it there first so two copies don't write to the same conversation."
    }

    /// Resumes the conversation in a ca-*-resume-* tmux session on the same host, then
    /// shows it in place of the Live view tab (if one is open). Checks once more that the
    /// original process is gone, unless `force` (the user said they closed it). Never
    /// touches the original process.
    func continueClaudeSession(host h: String, sessionId: String, cwd: String? = nil, force: Bool = false) {
        guard project != nil else {
            flash("Open a project first")
            return
        }
        guard let host = host(h), let name = resumeSessionName(host: host, sessionId: sessionId) else { return }
        // Already continued here: just show it.
        if let t = tabs.first(where: { $0.kind == .agent(.session(host: h, name: name)) }) {
            replaceLiveTab(host: h, sessionId: sessionId, with: t.id)
            return
        }
        Task { [weak self] in
            let d = SessionDiscovery.shared
            await d.refresh()
            guard let self else { return }
            if !force, d.isRunning(host: h, sessionId: sessionId) {
                self.flash("Still running, close it first")
                return
            }
            guard let dir = cwd ?? d.session(host: h, sessionId: sessionId)?.cwd, !dir.isEmpty else {
                self.flash("Couldn't find where this session ran")
                return
            }
            self.spawnResume(host: host, name: name, sessionId: sessionId, cwd: dir)
        }
    }

    private func spawnResume(host: Host, name: String, sessionId: String, cwd: String) {
        guard let project else { return }
        let pane = PaneSession(host: host, mode: .claude, session: name, cwd: cwd, env: projectEnv(project),
                               program: SessionResume.script(sessionId: sessionId, cwd: cwd))
        let live = tabs.firstIndex { $0.kind == .agent(.claude(host: host.id, sessionId: sessionId)) }
        let title = live.map { self.title(of: tabs[$0]) }
            ?? SessionDiscovery.shared.session(host: host.id, sessionId: sessionId).map { Self.shortTitle($0.title) }
        let tab = Tab(kind: .agent(.session(host: host.id, name: name)), title: title ?? "Resumed")
        agentPanes[tab.id] = pane
        pane.start()
        tabs.insert(tab, at: live.map { $0 + 1 } ?? tabs.count)
        replaceLiveTab(host: host.id, sessionId: sessionId, with: tab.id)
        monitor?.refreshNow()
    }

    /// Selects `id` and closes the session's Live view tab, if open.
    private func replaceLiveTab(host h: String, sessionId: String, with id: String) {
        select(id)
        if let live = tabs.first(where: { $0.kind == .agent(.claude(host: h, sessionId: sessionId)) }) {
            closeTab(live.id)
        }
    }

    // MARK: Orchestrator picker

    /// The session the Orchestrator tab shows instead of the project graph, while it's
    /// still known to discovery.
    var orchestratorPickedSession: ClaudeSession? {
        guard let id = orchestratorSessionPick else { return nil }
        return SessionDiscovery.shared.sessions.first { $0.id == id }
    }
}
