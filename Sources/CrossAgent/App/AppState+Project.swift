import Foundation

extension AppState {
    // MARK: Open and close

    var recentProjects: [RecentProject] { store.recents() }

    /// Loads the project into this window. A window keeps its project for life; other
    /// projects open in windows of their own (ProjectWindows).
    func openProject(_ url: URL) {
        guard project == nil else { return }
        let next = Project(url: url)
        project = next
        store.noteOpened(next)
        let state = store.loadState(for: next)
        setUpOrchestrator(for: next, on: state.orchestratorOn)
        restoreState(state, project: next)
        orchestratorRestored(workers: state.workerNodes ?? [])
        if let t = selectedTab { select(t.id) }
        monitor?.refreshNow()
    }

    /// Saves the project and closes its terminal clients, as its window goes away.
    /// Nothing is killed: tmux sessions keep running.
    func closeProject() {
        guard project != nil else { return }
        saveLayout()
        stopDemo()
        tearDownOrchestrator()
        closeAllPanes()
        orchestratorPane?.close()
        orchestratorPane = nil
        for p in agentPanes.values { p.close() }
        agentPanes = [:]
        // Done with it: a later save (quit) must not write the emptied grid over it.
        project = nil
    }

    /// Env every pane of the project gets.
    func projectEnv(_ project: Project) -> [String: String] {
        ["CROSSAGENT_PROJECT": project.slug]
    }

    // MARK: State

    /// Saves the open project's panes, mode, orchestrator and canvas. No-op without a
    /// project or while one is loading.
    func saveLayout() {
        guard let project, !isRestoring else { return }
        if let g = self.orch?.graph { finishedNodes = g.finished.compactMap { g.nodes[$0] } }
        var orch = orchestratorInfo
        if let o = orchestratorPane {
            orch = OrchestratorState(hostId: o.host.id, session: o.session, enabled: true)
        }
        let saved = savedTabs
        let state = ProjectState(
            panes: panes.map { SavedPane(hostId: $0.host.id, mode: $0.mode, session: $0.session) },
            mode: saved.tabs.first { $0.id == saved.selected }?.mode.rawValue,
            orchestrator: orch,
            nodePositions: savedNodePositions,
            finishedNodes: finishedNodes.isEmpty ? nil : finishedNodes,
            orchestratorOn: self.orch?.enabled,
            workerNodes: activeWorkerNodes.isEmpty ? nil : activeWorkerNodes,
            tabs: saved.tabs,
            selectedTab: saved.selected)
        store.saveState(state, for: project)
    }

    private func restoreState(_ state: ProjectState, project: Project) {
        isRestoring = true
        defer { isRestoring = false }
        for s in state.panes {
            guard let host = host(s.hostId), SessionName.isValid(s.session) else { continue }
            adopt(PaneSession(host: host, mode: s.mode, session: s.session, cwd: project.cwd(for: host),
                              env: projectEnv(project)))
        }
        orchestratorInfo = state.orchestrator
        if let o = state.orchestrator, o.enabled, let host = host(o.hostId), SessionName.isValid(o.session) {
            let pane = makeOrchestrator(host: host, session: o.session, project: project)
            orchestratorPane = pane
            pane.start()
        }
        nodePositions = state.nodePositions
        finishedNodes = state.finishedNodes ?? []
        restoreTabs(state)
        if let first = panes.first { focus(first.id) }
    }

    // MARK: Orchestrator

    /// Starts (or reattaches) the project's orchestrator Claude on `hostID`. A running
    /// one on another host is closed first; its tmux session keeps running.
    @discardableResult
    func startOrchestrator(hostID: String) -> PaneSession? {
        guard let project else {
            flash("Open a project first")
            return nil
        }
        guard let host = host(hostID) else { return nil }
        if let o = orchestratorPane {
            if o.host.id == host.id {
                if o.isExited { o.reconnect() }
                return o
            }
            o.close()
        }
        let session = CASessionName.orchestrator(slug: project.slug, host: host.id)
        let pane = makeOrchestrator(host: host, session: session, project: project)
        orchestratorPane = pane
        orchestratorInfo = OrchestratorState(hostId: host.id, session: session, enabled: true)
        pane.start()
        saveLayout()
        monitor?.refreshNow()
        return pane
    }

    /// Closes the orchestrator's client, and with `kill` its tmux session too.
    func stopOrchestrator(kill: Bool) {
        guard let pane = orchestratorPane else { return }
        orchestratorPane = nil
        orchestratorInfo = OrchestratorState(hostId: pane.host.id, session: pane.session, enabled: false)
        saveLayout()
        if kill {
            Task { [weak self] in
                await pane.killSession()
                self?.monitor?.refreshNow()
            }
        } else {
            pane.close()
        }
    }

    private func makeOrchestrator(host: Host, session: String, project: Project) -> PaneSession {
        var env = projectEnv(project)
        env["CROSSAGENT_ROLE"] = "orchestrator"
        return PaneSession(host: host, mode: .claude, session: session, cwd: project.cwd(for: host), env: env)
    }

    // MARK: Workers

    /// A started shell-mode pane attached to an EXISTING tmux session (a `ca run`
    /// worker, say). Never creates the session: if it is gone the process just exits.
    /// Not added to the grid; the caller owns it and must `close()` it. Nil for an
    /// unknown host or an invalid session name.
    func attachPane(host: Host, session: String) -> PaneSession? {
        guard SessionName.isValid(session) else { return nil }
        let pane = PaneSession(host: host, mode: .shell, session: session, attachOnly: true)
        pane.start()
        return pane
    }

    // MARK: Sync

    /// True when the project's folder exists on `host` (the remote copy for ssh hosts).
    func remoteFolderExists(host: Host) async -> Bool {
        guard let project else { return false }
        if host.isLocal { return ProjectStore.folderExists(project.path) }
        let script = "test -d " + CommandBuilder.shellPath(project.cwd(for: host))
        return await Runner.run(CommandBuilder.oneShot(host: host, script: script), timeout: 30).status == 0
    }

    /// Opens the project's Crossover Portal with `ca sync start`, the command's old name.
    /// It stays a permanent alias, so skills installed before the rename work too.
    /// Output is stdout and stderr.
    /// The first connect to a fresh host uploads Mutagen's agent, so it can take a minute.
    func startSync() async -> (ok: Bool, output: String) {
        guard let project else { return (false, "No project open") }
        #if DEBUG
        if DemoMode.isOn { return (true, "Portal open: ~/Projects/demo <-> pc:~/Projects/demo") }
        #endif
        let path = CommandBuilder.shellQuote(project.path)
        let script = CommandBuilder.pathPrefix
            + "cd \(path) && CA_ROOT=\(path) exec \"$HOME/.claude/skills/crossagent/scripts/ca\" sync start"
        let r = await Runner.run(SpawnCommand(executable: LocalShell.path, args: ["-lc", script]), timeout: 300)
        let out = [r.stdout, r.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return (r.status == 0, out)
    }
}
