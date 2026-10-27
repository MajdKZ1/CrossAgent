import Combine
import Foundation

/// A relay from one canvas node to another, waiting in the "Send to" card.
struct NodeRelay: Equatable {
    var from: String
    var to: String
    var text: String
}

/// Orchestrator mode for one open project: the agent graph, the event pipeline that
/// feeds it, and what the canvas has open on top (detail card, relay card).
/// Made when a project opens, stopped and dropped when it closes.
@MainActor
final class ProjectOrchestrator: ObservableObject {
    let graph: AgentGraph
    let controller: OrchestratorController
    /// Hooks installed and events followed. Saved with the project.
    @Published var enabled: Bool
    /// Hooks are being installed.
    @Published var busy = false
    /// Node shown in the detail card.
    @Published var detail: String?
    /// Set when the card was opened to answer a prompt for another node.
    @Published var answering: String?
    @Published var relay: NodeRelay?
    /// Attached terminals for workers, by node id. Never create a session.
    @Published var workerPanes: [String: PaneSession] = [:]

    var watchers: Set<AnyCancellable> = []
    var saveTask: Task<Void, Never>?
    var demoTimer: Timer?

    init(graph: AgentGraph, controller: OrchestratorController, enabled: Bool) {
        self.graph = graph
        self.controller = controller
        self.enabled = enabled
    }
}

extension AppState {
    // MARK: Lifetime

    /// Builds the graph and controller for `project`. With `on` (or our hooks already
    /// in the settings when the project never said) the followers start right away,
    /// so the graph is current whatever mode the window is in.
    func setUpOrchestrator(for project: Project, on: Bool?) {
        tearDownOrchestrator()
        let graph = AgentGraph(orchestratorHost: hosts.first(where: \.isLocal)?.id ?? "mac")
        let controller = OrchestratorController(slug: project.slug, macPath: project.path,
                                                pcRelativePath: project.pcRelativePath, hosts: hosts, graph: graph)
        let o = ProjectOrchestrator(graph: graph, controller: controller, enabled: on ?? controller.isEnabled)
        orch = o
        $orchestratorPane
            .sink { [weak self] pane in self?.syncOrchestratorNode(pane) }
            .store(in: &o.watchers)
        graph.$finished
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleOrchestratorSave() }
            .store(in: &o.watchers)
    }

    /// After the project state loaded: finished nodes back on the canvas, followers on.
    func orchestratorRestored() {
        guard let o = orch else { return }
        let kept = finishedNodes.filter { o.graph.nodes[$0.id] == nil && $0.kind != .orchestrator }
        for n in kept { o.graph.nodes[n.id] = n }
        o.graph.finished = kept.map(\.id)
        syncOrchestratorNode(orchestratorPane)
        if o.enabled {
            o.controller.start()
            // Refreshes the hook script, and adds the hooks on a host whose folder showed up since.
            Task { await enableOrchestrator() }
        }
    }

    /// Stops following and closes every attached worker terminal. Sessions keep running.
    func tearDownOrchestrator() {
        guard let o = orch else { return }
        o.controller.stop()
        o.demoTimer?.invalidate()
        o.saveTask?.cancel()
        for pane in o.workerPanes.values { pane.close() }
        o.workerPanes = [:]
        o.watchers = []
        orch = nil
    }

    private func syncOrchestratorNode(_ pane: PaneSession?) {
        guard let g = orch?.graph, var n = g.orchestrator else { return }
        if pane == nil, n.tmuxSession != nil { n.state = .idle; n.activity = "Stopped" }
        if pane != nil, n.tmuxSession == nil, n.activity == "Stopped" { n.activity = "Idle" }
        n.hostId = pane?.host.id ?? orchestratorInfo?.hostId ?? n.hostId
        n.tmuxSession = pane?.session
        if n != g.orchestrator { g.nodes[AgentGraph.orchestratorID] = n }
    }

    /// Saves positions and finished nodes a moment after the last change.
    func scheduleOrchestratorSave() {
        guard let o = orch else { return }
        o.saveTask?.cancel()
        o.saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { self?.saveLayout() }
        }
    }

    // MARK: On and off

    /// Installs the hook script everywhere and our hooks in the project's settings on
    /// the Mac and on every host that has the project folder, then follows events.
    func enableOrchestrator() async {
        guard let o = orch, let project else { return }
        o.busy = true
        defer { o.busy = false }
        var skip: Set<String> = []
        for h in hosts where !h.isLocal {
            if !(await remoteFolderExists(host: h)) { skip.insert(h.id) }
        }
        guard orch === o, self.project?.path == project.path else { return }
        let failed = await o.controller.enable(skipSettings: skip)
        guard orch === o else { return }
        let wasOn = o.enabled
        o.enabled = true
        if !wasOn { saveLayout() }
        if !failed.isEmpty {
            let names = failed.map { id in host(id)?.name ?? (id == "mac-settings" ? "this Mac" : id) }
            flash("Couldn't add hooks on " + names.joined(separator: ", "))
        }
    }

    /// Hooks first, so Claude sees them when it starts, then the session.
    func launchOrchestrator(hostID: String) {
        guard project != nil, let o = orch, !o.busy else { return }
        if o.enabled && o.controller.isRunning {
            startOrchestrator(hostID: hostID)
            return
        }
        Task { [weak self] in
            await self?.enableOrchestrator()
            guard let self, self.orch === o else { return }
            self.startOrchestrator(hostID: hostID)
        }
    }

    /// Removes only our hooks on every host, stops following and goes back to the panes.
    /// The orchestrator session keeps running.
    func turnOffOrchestrator() {
        guard let o = orch, o.enabled || o.controller.isEnabled else { return }
        closeNodeOverlays()
        o.busy = true
        Task { [weak self] in
            await o.controller.disable()
            o.busy = false
            o.enabled = false
            guard let self, self.orch === o else { return }
            self.saveLayout()
            self.flash("Orchestrator off, hooks removed")
        }
        if mode == .orchestrator { mode = .panes }
    }

    /// Entering the mode with an orchestrator already running turns the pipeline on.
    func orchestratorModeChanged(from old: AppMode) {
        guard !isRestoring, let o = orch else { return }
        if mode == .orchestrator, orchestratorPane != nil, !o.enabled, !o.busy {
            Task { await enableOrchestrator() }
        }
        if old == .orchestrator { closeNodeOverlays() }
    }

    func clearFinishedAgents() {
        guard let g = orch?.graph else { return }
        for id in g.finished { nodePositions[id] = nil }
        g.clearFinished()
        saveLayout()
    }

    // MARK: Detail card

    /// Opens the detail card for a node. Workers get an attached terminal.
    func expandNode(_ id: String) {
        guard let o = orch, let node = o.graph.nodes[id] else { return }
        if let old = o.detail, old != id { releaseWorkerPane(old) }
        o.answering = nil
        o.detail = id
        o.relay = nil
        if node.kind == .worker { _ = workerPane(for: node) }
        focusDetailTerminal()
    }

    /// Opens the card on the terminal that shows the node's prompt: its own, else the
    /// orchestrator's (built-in subagents ask in there).
    func answerNode(_ id: String) {
        guard let o = orch, let node = o.graph.nodes[id] else { return }
        if node.kind == .worker, node.tmuxSession != nil {
            expandNode(id)
        } else {
            expandNode(AgentGraph.orchestratorID)
            if id != AgentGraph.orchestratorID { o.answering = node.name }
        }
    }

    func closeDetail() {
        guard let o = orch, let id = o.detail else { return }
        o.detail = nil
        o.answering = nil
        releaseWorkerPane(id)
        if let win = window, win.firstResponder is PaneTerminalView { win.makeFirstResponder(nil) }
    }

    func closeNodeOverlays() {
        orch?.relay = nil
        closeDetail()
    }

    /// The terminal the detail card shows, if it has one.
    var detailTerminal: PaneSession? {
        guard let o = orch, let id = o.detail, let node = o.graph.nodes[id] else { return nil }
        switch node.kind {
        case .orchestrator: return orchestratorPane
        case .worker: return o.workerPanes[id]
        case .subagent: return nil
        }
    }

    private func focusDetailTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let t = self?.detailTerminal?.terminal else { return }
            t.window?.makeFirstResponder(t)
        }
    }

    /// The worker's attached terminal, made on first use. Nil when it has no session
    /// or its host is unknown.
    func workerPane(for node: AgentNode) -> PaneSession? {
        guard let o = orch, let session = node.tmuxSession, let host = host(node.hostId) else { return nil }
        if let p = o.workerPanes[node.id] {
            if p.isExited { p.reconnect() }
            return p
        }
        guard let p = attachPane(host: host, session: session) else { return nil }
        o.workerPanes[node.id] = p
        return p
    }

    private func releaseWorkerPane(_ id: String) {
        guard let o = orch, let p = o.workerPanes.removeValue(forKey: id) else { return }
        p.close()
    }

    // MARK: Sending

    /// Text from the detail card's input box: built-in subagents get `@name text` through
    /// the orchestrator, terminals get the text and Enter.
    func sendToNode(_ id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let node = orch?.graph.nodes[id] else { return }
        if node.kind == .subagent {
            sendViaOrchestrator(to: node, text: text)
        } else {
            paste(text, into: node, enter: true)
        }
    }

    /// Opens the "Send to" card, prefilled with the source terminal's selection.
    func openNodeRelay(from: String, to: String) {
        guard let o = orch, from != to, o.graph.nodes[to] != nil else { return }
        var source: PaneSession?
        if from == AgentGraph.orchestratorID { source = orchestratorPane } else { source = o.workerPanes[from] }
        o.relay = NodeRelay(from: from, to: to, text: source?.selectedText ?? "")
    }

    /// Sends the relay card's text. Terminals get a paste without Enter, like relay in
    /// the grid; built-in subagents get `@name text` through the orchestrator.
    func sendNodeRelay(_ relay: NodeRelay) {
        orch?.relay = nil
        let text = relay.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty, let node = orch?.graph.nodes[relay.to] else { return }
        if node.kind == .subagent {
            sendViaOrchestrator(to: node, text: text)
        } else {
            paste(text, into: node, enter: false)
        }
    }

    private func sendViaOrchestrator(to node: AgentNode, text: String) {
        guard let o = orchestratorPane, o.isLive else {
            flash("Start the orchestrator first")
            return
        }
        o.sendPaste("@\(node.name) \(text)")
        pressEnter(in: o)
        flash("Sent to orchestrator for \(node.name)")
    }

    private func paste(_ text: String, into node: AgentNode, enter: Bool) {
        let label = node.kind == .orchestrator ? "orchestrator" : node.name
        if node.kind == .orchestrator {
            guard let o = orchestratorPane, o.isLive else {
                flash("Start the orchestrator first")
                return
            }
            o.sendPaste(text)
            if enter { pressEnter(in: o) }
            flash(enter ? "Sent to \(label)" : "Relayed \(text.count) chars to \(label)")
            return
        }
        guard let o = orch, let pane = workerPane(for: node) else {
            flash("This worker has no terminal")
            return
        }
        let id = node.id
        Task { [weak self] in
            // Bytes written before tmux attaches can be dropped, so wait for its first output.
            let deadline = Date().addingTimeInterval(8)
            while pane.state == .connecting, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            guard pane.isLive else {
                self.flash("This worker's session has ended")
                if o.detail != id { self.releaseWorkerPane(id) }
                return
            }
            pane.sendPaste(text)
            if enter { self.pressEnter(in: pane) }
            self.flash(enter ? "Sent to \(label)" : "Relayed \(text.count) chars to \(label)")
            // A terminal opened just for this goes away once tmux has the text.
            if o.detail != id {
                try? await Task.sleep(for: .seconds(1))
                if o.detail != id { self.releaseWorkerPane(id) }
            }
        }
    }

    /// Enter through the same path as a keypress, a beat after the paste so the app
    /// inside does not take it as part of the paste.
    private func pressEnter(in pane: PaneSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pane.terminal.send(source: pane.terminal, data: [13])
        }
    }

    // MARK: Dev

    /// Plays DemoEvents into the current graph, with ticks.
    func playDemo() {
        guard let o = orch, let project else { return }
        o.demoTimer?.invalidate()
        let start = Date()
        var steps = DemoEvents.script(slug: project.slug, start: start).enumerated()
            .sorted { ($0.element.delay, $0.offset) < ($1.element.delay, $1.offset) }.map(\.element)[...]
        var lastTick = start
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak o] t in
            MainActor.assumeIsolated {
                guard let o else { t.invalidate(); return }
                let elapsed = Date().timeIntervalSince(start)
                while let s = steps.first, s.delay <= elapsed {
                    o.graph.apply(s.event)
                    steps.removeFirst()
                }
                if Date().timeIntervalSince(lastTick) >= 3 {
                    lastTick = Date()
                    o.graph.tick(now: Date())
                }
                if steps.isEmpty, elapsed > 60 { t.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        o.demoTimer = timer
    }

    /// Applies events through the project filter, like the followers do.
    func injectEvents(_ events: [AgentEvent]) {
        guard let o = orch else { return }
        o.graph.apply(events, project: o.controller.slug, projectPaths: o.controller.projectPaths)
    }
}
