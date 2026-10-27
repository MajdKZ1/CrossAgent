import Combine
import Foundation

/// A relay from one canvas node to another, waiting in the "Send to" card.
struct NodeRelay: Equatable {
    var from: String
    var to: String
    var text: String
}

/// Orchestrator mode for one open project: the agent graph, the event pipeline that
/// feeds it, and the relay card the canvas has open on top.
/// Made when a project opens, stopped and dropped when it closes.
@MainActor
final class ProjectOrchestrator: ObservableObject {
    let graph: AgentGraph
    let controller: OrchestratorController
    /// Hooks installed and events followed. Saved with the project.
    @Published var enabled: Bool
    /// Hooks are being installed.
    @Published var busy = false
    /// Set when the orchestrator's tab was opened to answer a prompt for another node.
    @Published var answering: String?
    @Published var relay: NodeRelay?
    /// Short lived attached terminals for workers without a tab, by node id, made to
    /// paste a message and dropped again. Never create a session.
    @Published var workerPanes: [String: PaneSession] = [:]
    /// Which tab a remote worker's card shows, by node id. Terminal when unset.
    @Published var remoteTabs: [String: RemoteCardTab] = [:]
    /// Brief and result text read from the worker's host, by `RemoteDoc.slot`.
    @Published var remoteDocs: [String: RemoteDoc] = [:]
    /// Approval answers on their way, by permission id.
    @Published var permissionSends: [String: PermissionSend] = [:]

    /// The demo plays in here, never in `graph`, so nothing of it is saved.
    @Published var demoGraph: AgentGraph?
    /// What the canvas and the cards show.
    var shown: AgentGraph { demoGraph ?? graph }
    /// Where the demo's nodes were dragged. Thrown away with the demo.
    var demoPositions: [String: CGPoint] = [:]
    /// The DemoMode story playing in `demoGraph`, if any. Unlike the dev demo it stays
    /// up while other tabs show, so its agents' cards can be opened.
    var story: String?

    var watchers: Set<AnyCancellable> = []
    var saveTask: Task<Void, Never>?
    var demoTimer: Timer?
    /// Keeps workers that are busy in tmux from dozing off. See `keepBusyWorkers`.
    var busyTimer: Timer?
    /// Restored running workers whose tmux session has not been checked yet.
    var unverifiedWorkers: Set<String> = []
    /// Prompt sessions ("host/session") the monitor has seen waiting for input.
    var seenWaiting: Set<String> = []
    /// This project asked the monitor to poll fast.
    var monitorFast = false

    init(graph: AgentGraph, controller: OrchestratorController, enabled: Bool) {
        self.graph = graph
        self.controller = controller
        self.enabled = enabled
    }
}

extension AppState {
    /// The local host's id from hosts.json, for graphs whose orchestrator runs here.
    var localHostID: String { hosts.first(where: \.isLocal)?.id ?? hosts.first?.id ?? "local" }

    // MARK: Lifetime

    /// Builds the graph and controller for `project`. With `on` (or our hooks already
    /// in the settings when the project never said) the followers start right away,
    /// so the graph is current whatever mode the window is in.
    func setUpOrchestrator(for project: Project, on: Bool?) {
        tearDownOrchestrator()
        let graph = AgentGraph(orchestratorHost: localHostID, hosts: hosts)
        let controller = OrchestratorController(slug: project.slug, macPath: project.path,
                                                pcRelativePath: project.pcRelativePath, hosts: hosts, graph: graph)
        let o = ProjectOrchestrator(graph: graph, controller: controller, enabled: on ?? controller.isEnabled)
        orch = o
        wireOrchestrator(o)
    }

    /// Hooks the graph up to this window's state.
    func wireOrchestrator(_ o: ProjectOrchestrator) {
        o.watchers = []
        let graph = o.graph
        $orchestratorPane
            .sink { [weak self] pane in self?.syncOrchestratorNode(pane) }
            .store(in: &o.watchers)
        graph.$finished
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleOrchestratorSave() }
            .store(in: &o.watchers)
        // Running workers are saved too, so they survive a relaunch.
        graph.$nodes
            .map { nodes in Set(nodes.values.filter { $0.kind == .worker }.map(\.id)) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleOrchestratorSave() }
            .store(in: &o.watchers)
        // Published in willSet, so read the new values on the next turn.
        graph.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkNeedsInput() }
            .store(in: &o.watchers)
        monitor?.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pruneRestoredWorkers()
                self?.endGoneWorkers()
                self?.checkNeedsInput()
            }
            .store(in: &o.watchers)
        // The monitor only publishes when a poll differs, and a worker running a quiet
        // command changes nothing, so check its last poll on a timer.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let sessions = self.monitor?.sessions else { return }
                self.orch?.graph.keepBusyWorkers(sessions, now: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        o.busyTimer = timer
    }

    /// After the project state loaded: finished nodes and running workers back on the
    /// canvas, followers on. Workers whose session is gone drop once their host is polled.
    func orchestratorRestored(workers: [AgentNode]) {
        guard let o = orch else { return }
        let kept = finishedNodes.filter { o.graph.nodes[$0.id] == nil && $0.kind != .orchestrator }
        for n in kept { o.graph.nodes[n.id] = n }
        o.graph.finished = kept.map(\.id)
        for n in workers where n.kind == .worker && n.tmuxSession != nil && o.graph.nodes[n.id] == nil {
            o.graph.nodes[n.id] = n
            o.unverifiedWorkers.insert(n.id)
        }
        pruneRestoredWorkers()
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
        o.busyTimer?.invalidate()
        o.demoTimer?.invalidate()
        o.saveTask?.cancel()
        if o.monitorFast { monitor?.setActive(false, for: ObjectIdentifier(o)) }
        o.monitorFast = false
        for pane in o.workerPanes.values { pane.close() }
        o.workerPanes = [:]
        o.watchers = []
        orch = nil
    }

    func syncOrchestratorNode(_ pane: PaneSession?) {
        guard let g = orch?.graph, var n = g.orchestrator else { return }
        if pane == nil, n.tmuxSession != nil { n.state = .idle; n.activity = "Stopped" }
        if pane != nil, n.tmuxSession == nil, n.activity == "Stopped" { n.activity = "Idle" }
        n.hostId = pane?.host.id ?? orchestratorInfo?.hostId ?? n.hostId
        n.tmuxSession = pane?.session
        if n != g.orchestrator { g.nodes[AgentGraph.orchestratorID] = n }
    }

    /// Running workers of the real graph, saved with the project.
    var activeWorkerNodes: [AgentNode] {
        guard let g = orch?.graph else { return [] }
        return g.nodes.values.filter { $0.kind == .worker && !g.finished.contains($0.id) }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Drops restored workers whose tmux session is gone, once their host answered a poll.
    private func pruneRestoredWorkers() {
        guard let o = orch, !o.unverifiedWorkers.isEmpty, let monitor else { return }
        var dropped = false
        for id in o.unverifiedWorkers {
            guard let n = o.graph.nodes[id], let session = n.tmuxSession else {
                o.unverifiedWorkers.remove(id)
                continue
            }
            guard monitor.reachable[n.hostId] == true else { continue }
            o.unverifiedWorkers.remove(id)
            if !(monitor.sessions[n.hostId] ?? []).contains(where: { $0.name == session }) {
                o.graph.nodes[id] = nil
                nodePositions[id] = nil
                dropped = true
            }
        }
        if dropped { scheduleOrchestratorSave() }
    }

    /// Workers whose tmux session went away (`ca stop`, a kill, a crash) are done.
    /// Young nodes get a grace period, since a poll that started before their session
    /// existed can land after their WorkerStart event.
    private func endGoneWorkers() {
        guard let o = orch, let monitor else { return }
        let g = o.graph
        let now = Date()
        var ended: [String] = []
        for n in g.nodes.values where n.kind == .worker && n.remote == nil && !o.unverifiedWorkers.contains(n.id) {
            switch n.state {
            case .done, .error: continue
            default: break
            }
            guard let session = n.tmuxSession, monitor.reachable[n.hostId] == true,
                  let live = monitor.sessions[n.hostId], now.timeIntervalSince(n.startedAt) > 20,
                  !live.contains(where: { $0.name == session }) else { continue }
            ended.append(n.id)
        }
        guard !ended.isEmpty else { return }
        for id in ended {
            g.nodes[id]?.state = .done
            g.nodes[id]?.activity = "Session ended"
            g.nodes[id]?.finishedAt = now
            g.nodes[id]?.updatedAt = now
            g.nodes[id]?.flow = .toOrchestrator
            g.nodes[id]?.flowAt = now
            g.finished.removeAll { $0 == id }
            g.finished.append(id)
        }
        while g.finished.count > AgentGraph.keepFinished {
            g.nodes[g.finished.removeFirst()] = nil
        }
    }

    /// Positions worth saving: only nodes the real graph still has.
    var savedNodePositions: [String: CGPoint] {
        guard let g = orch?.graph else { return nodePositions }
        return nodePositions.filter { g.nodes[$0.key] != nil }
    }

    // MARK: Needs input

    /// Sessions holding a prompt: a worker's own, else the orchestrator's (built-in
    /// subagents ask in there). As "host/session" keys.
    private func promptSessions(_ g: AgentGraph) -> [String: (host: String, session: String)] {
        var out: [String: (host: String, session: String)] = [:]
        for n in g.nodes.values {
            guard case .needsInput = n.state else { continue }
            // Remote approvals clear through PermissionAnswer, not the screen.
            guard n.remote?.permission == nil else { continue }
            let holder = n.kind == .worker ? n : g.orchestrator
            guard let h = holder, let s = h.tmuxSession else { continue }
            out[h.hostId + "/" + s] = (h.hostId, s)
        }
        return out
    }

    /// Approving a permission sends no hook event, so watch the prompt's tmux session:
    /// once it was seen waiting and is not anymore, the prompt was answered. The monitor
    /// polls fast while the canvas is up and something needs input.
    func checkNeedsInput() {
        guard let o = orch, let monitor else { return }
        let prompts = promptSessions(o.graph)
        let want = mode == .orchestrator && !prompts.isEmpty
        if want != o.monitorFast { monitor.setActive(want, for: ObjectIdentifier(o)) }
        o.monitorFast = want
        o.seenWaiting.formIntersection(prompts.keys)
        for (key, p) in prompts {
            guard let info = monitor.sessions[p.host]?.first(where: { $0.name == p.session }) else { continue }
            if info.status == .waitingForInput {
                o.seenWaiting.insert(key)
            } else if o.seenWaiting.contains(key) {
                o.seenWaiting.remove(key)
                o.graph.resolveNeedsInput(tmuxSession: p.session)
            }
        }
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
        if DemoMode.isOn {
            // Nothing to install and no host to ask: the controller only flips on.
            _ = await o.controller.enable()
            o.enabled = true
            return
        }
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
        o.relay = nil
        o.busy = true
        Task { [weak self] in
            await o.controller.disable()
            o.busy = false
            o.enabled = false
            guard let self, self.orch === o else { return }
            self.saveLayout()
            self.flash("Orchestrator off, hooks removed")
        }
        if mode == .orchestrator { open(.panes) }
    }

    /// Entering the mode with an orchestrator already running turns the pipeline on.
    func orchestratorModeChanged(from old: AppMode) {
        guard !isRestoring, let o = orch else { return }
        if mode == .orchestrator, orchestratorPane != nil, !o.enabled, !o.busy {
            Task { await enableOrchestrator() }
        }
        if old == .orchestrator {
            o.relay = nil
            if o.story == nil { stopDemo() }
        }
        // Once the new tab has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.checkNeedsInput() }
    }

    func clearFinishedAgents() {
        guard let o = orch else { return }
        let g = o.shown
        if o.demoGraph == nil { for id in g.finished { nodePositions[id] = nil } }
        g.clearFinished()
        saveLayout()
    }

    // MARK: Opening nodes

    /// A canvas node click: the node's agent tab.
    func expandNode(_ id: String) {
        orch?.relay = nil
        openAgent(.node(id))
    }

    /// Opens the tab on the terminal that shows the node's prompt: its own, else the
    /// orchestrator's (built-in subagents ask in there).
    func answerNode(_ id: String) {
        guard let o = orch, let node = o.shown.nodes[id] else { return }
        o.relay = nil
        if node.remote?.permission != nil {
            // Remote approvals are answered on the node's own card.
            openAgent(.node(id))
        } else if node.kind == .worker, node.tmuxSession != nil {
            openAgent(.node(id))
        } else {
            openAgent(.node(AgentGraph.orchestratorID))
            if id != AgentGraph.orchestratorID { o.answering = node.name }
        }
    }

    /// The relay card, and the selected agent tab.
    func closeNodeOverlays() {
        if let o = orch, o.relay != nil {
            o.relay = nil
        } else if selectedTab?.isAgent == true {
            closeTab()
        }
    }

    /// The worker's attached terminal: its agent tab's if one is open, else a short
    /// lived one made on first use. Nil when it has no session or its host is unknown.
    func workerPane(for node: AgentNode) -> PaneSession? {
        guard let o = orch, let session = node.remote.flatMap({ $0.tmuxSession.isEmpty ? nil : $0.tmuxSession }) ?? node.tmuxSession,
              let host = host(node.remote?.host ?? node.hostId) else { return nil }
        if let p = agentPane(host: host.id, session: session) ?? remoteCardPane(node.id) {
            if p.isExited { p.reconnect() }
            return p
        }
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

    /// Text from an agent tab's input box: built-in subagents get `@name text` through
    /// the orchestrator, terminals get the text and Enter.
    func sendToNode(_ id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let node = orch?.shown.nodes[id] else { return }
        if node.kind == .subagent {
            sendViaOrchestrator(to: node, text: text)
        } else {
            paste(text, into: node, enter: true)
        }
    }

    /// Opens the "Send to" card, prefilled with the source terminal's selection.
    func openNodeRelay(from: String, to: String) {
        guard let o = orch, from != to, o.shown.nodes[to] != nil else { return }
        var source: PaneSession?
        if from == AgentGraph.orchestratorID {
            source = orchestratorPane
        } else if let n = o.shown.nodes[from], let s = n.tmuxSession {
            source = agentPane(host: n.hostId, session: s) ?? o.workerPanes[from]
        }
        o.relay = NodeRelay(from: from, to: to, text: source?.selectedText ?? "")
    }

    /// Sends the relay card's text. Terminals get a paste without Enter, like relay in
    /// the grid; built-in subagents get `@name text` through the orchestrator.
    func sendNodeRelay(_ relay: NodeRelay) {
        orch?.relay = nil
        let text = relay.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty, let node = orch?.shown.nodes[relay.to] else { return }
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
                self.releaseWorkerPane(id)
                return
            }
            pane.sendPaste(text)
            if enter { self.pressEnter(in: pane) }
            self.flash(enter ? "Sent to \(label)" : "Relayed \(text.count) chars to \(label)")
            // A terminal opened just for this goes away once tmux has the text. A tab's
            // own terminal is not in workerPanes, so it stays.
            if o.workerPanes[id] != nil {
                try? await Task.sleep(for: .seconds(1))
                self.releaseWorkerPane(id)
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

    /// Plays DemoEvents on the canvas, with ticks. It runs in a throwaway graph, so the
    /// project's graph and saved state never see it. Ends 15 s after the script.
    func playDemo() {
        guard let o = orch, let project else { return }
        stopDemo()
        o.demoPositions = [:]
        let real = o.graph.orchestrator
        let graph = AgentGraph(orchestratorHost: real?.hostId ?? localHostID, session: real?.tmuxSession, hosts: hosts)
        o.demoGraph = graph
        let start = Date()
        var steps = DemoEvents.script(slug: project.slug, start: start).enumerated()
            .sorted { ($0.element.delay, $0.offset) < ($1.element.delay, $1.offset) }.map(\.element)[...]
        let end = (steps.last?.delay ?? 0) + 15
        var lastTick = start
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.orch?.demoGraph === graph else { t.invalidate(); return }
                let elapsed = Date().timeIntervalSince(start)
                while let s = steps.first, s.delay <= elapsed {
                    graph.apply(s.event)
                    steps.removeFirst()
                }
                if Date().timeIntervalSince(lastTick) >= 3 {
                    lastTick = Date()
                    graph.tick(now: Date())
                }
                if elapsed > end { self.stopDemo() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        o.demoTimer = timer
    }

    /// Back to the project's real graph.
    func stopDemo() {
        guard let o = orch, o.demoGraph != nil else { return }
        o.demoTimer?.invalidate()
        o.demoTimer = nil
        o.story = nil
        if let r = o.relay, o.graph.nodes[r.to] == nil { o.relay = nil }
        o.demoGraph = nil
    }

    // MARK: Demo stories

    /// Plays a `DemoStory` on the Orchestrator tab, in a throwaway graph like the dev
    /// demo. DemoMode only. `loop` replays the hero story, clearing back to the lone
    /// orchestrator in between. Without `autoAllow` the approval waits for a click.
    func playStory(_ name: String, loop: Bool = false, autoAllow: Bool = true) {
        guard DemoMode.isOn, let o = orch else { return }
        if name == "reset" {
            resetStory()
            return
        }
        guard DemoStory.names.contains(name) else { return }
        stopDemo()
        o.demoPositions = [:]
        o.permissionSends = [:]
        o.relay = nil
        let real = o.graph.orchestrator
        let graph = AgentGraph(orchestratorHost: real?.hostId ?? localHostID, session: real?.tmuxSession, hosts: hosts)
        o.demoGraph = graph
        o.story = name
        runStory(name, in: graph, loop: loop, autoAllow: autoAllow)
    }

    /// Back to the lone orchestrator, its agents shrinking home. Stays on the demo graph.
    func resetStory() {
        guard DemoMode.isOn, let o = orch else { return }
        o.demoTimer?.invalidate()
        o.demoTimer = nil
        guard let graph = o.demoGraph else {
            playStory("hero")
            resetStory()
            return
        }
        clearStory(graph)
    }

    private func runStory(_ name: String, in graph: AgentGraph, loop: Bool, autoAllow: Bool) {
        guard let o = orch, let project else { return }
        let start = Date()
        let pc = hosts.first { !$0.isLocal }?.id ?? "pc"
        var steps = (DemoStory.steps(name, slug: project.slug, mac: graph.orchestratorHost, pc: pc, start: start) ?? [])[...]
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let o = self.orch, o.demoGraph === graph else { t.invalidate(); return }
                let elapsed = Date().timeIntervalSince(start)
                while let s = steps.first, s.at <= elapsed {
                    steps.removeFirst()
                    self.storyCue(s.cue, in: graph, autoAllow: autoAllow)
                }
                guard steps.isEmpty else { return }
                if !loop || name != "hero" {
                    t.invalidate()
                    return
                }
                guard elapsed >= DemoStory.heroLength else { return }
                t.invalidate()
                self.clearStory(graph)
                DispatchQueue.main.asyncAfter(deadline: .now() + DemoStory.loopGap) { [weak self] in
                    guard let self, let o = self.orch, o.demoGraph === graph, o.story == name else { return }
                    self.runStory(name, in: graph, loop: loop, autoAllow: autoAllow)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        o.demoTimer = timer
    }

    private func storyCue(_ cue: DemoStory.Cue, in graph: AgentGraph, autoAllow: Bool) {
        switch cue {
        case .event(let e):
            graph.apply(e)
        case .allow(let id):
            if autoAllow { answerPermission(nodeID: id, allow: true) }
        case .doze(let id, let activity):
            graph.update(id, at: Date()) {
                $0.state = .idle
                $0.activity = activity
                AgentGraph.push(activity, into: &$0.recent)
            }
        case .clear:
            clearStory(graph)
        }
    }

    private func clearStory(_ graph: AgentGraph) {
        let now = Date()
        var lone = graph.orchestrator
        lone?.state = .idle
        lone?.activity = "Ready"
        lone?.recent = []
        lone?.updatedAt = now
        lone?.flow = .none
        graph.remoteTable = RemoteTable()
        graph.finished = []
        graph.nodes = lone.map { [AgentGraph.orchestratorID: $0] } ?? [:]
        orch?.permissionSends = [:]
        orch?.demoPositions = [:]
    }

    /// DemoMode's answer to an approval: nothing written, no ssh. The card goes through
    /// sending and sent like a real answer, then the PermissionAnswer comes in locally.
    func demoAnswerPermission(nodeID: String, allow: Bool) {
        guard let o = orch, let r = o.shown.nodes[nodeID]?.remote, let ask = r.permission,
              o.permissionSends[ask.id] == nil else { return }
        let graph = o.shown
        o.permissionSends[ask.id] = .sending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard o.shown === graph else { return }
            o.permissionSends[ask.id] = .sent(allow: allow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard o.shown === graph else { return }
                graph.apply(DemoStory.permissionAnswer(host: r.host, role: r.role, tmux: r.tmuxSession, req: ask.id,
                                                       allow: allow))
                o.permissionSends[ask.id] = nil
            }
        }
    }

    /// Applies events through the project filter, like the followers do.
    func injectEvents(_ events: [AgentEvent]) {
        guard let o = orch else { return }
        o.graph.apply(events, project: o.controller.slug, projectPaths: o.controller.projectPaths)
        RemoteEventLog.add(events, project: o.controller.slug)
    }
}

extension AgentGraph {
    /// True when a `ca run` worker's tmux session says it is busy. It stays busy until
    /// its WorkerStop marks it done: tmux shows `bash` in front either way, so
    /// `yes > /dev/null` and `read x` look alike from outside.
    nonisolated static func workerBusy(_ s: TmuxSessionInfo) -> Bool {
        !(s.paneDead || s.status == .waitingForInput || s.status == .exited)
    }

    /// Workers emit no events while a long command runs, so `tick` would doze them off.
    /// Every few seconds, busy workers are marked working and their clock bumped. Quiet
    /// ones are left alone and go idle through `tick` as before. Remote workers are left
    /// out: their running turn keeps them alive.
    func keepBusyWorkers(_ sessions: [String: [TmuxSessionInfo]], now: Date) {
        for (id, n) in nodes where n.kind == .worker && n.remote == nil {
            guard let session = n.tmuxSession,
                  let info = sessions[n.hostId]?.first(where: { $0.name == session }) else { continue }
            guard Self.workerBusy(info) else { continue }
            var m = n
            switch n.state {
            case .idle:
                m.state = .working
                if m.activity.isEmpty || m.activity == "Idle" { m.activity = "Running" }
            case .working, .thinking:
                break
            default:
                continue
            }
            m.updatedAt = max(m.updatedAt, now)
            nodes[id] = m
        }
    }
}
