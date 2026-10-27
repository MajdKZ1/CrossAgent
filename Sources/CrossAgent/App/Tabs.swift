import AppKit
import Combine
import Foundation

// The single window tab strip. Other parts of the app (canvas, station, activity,
// mascot orbs) only call `openAgent`.

/// Something that can be opened as an agent chat tab.
enum AgentRef: Hashable, Codable {
    /// A node in the current project's AgentGraph (orchestrator, subagent or worker).
    case node(String)
    /// Any tmux session on a host, opened as its live terminal.
    case session(host: String, name: String)
}

/// One tab in the main window.
enum TabKind: Hashable, Codable {
    case welcome, panes, station, orchestrator, activity
    case agent(AgentRef)
    /// Dev only views (CROSSAGENT_ORCH_DEMO, CROSSAGENT_MASCOT_GALLERY). Never saved.
    case dev(DevTab)
}

enum DevTab: String, Codable { case orchestratorDemo, mascotGallery }

struct Tab: Identifiable, Hashable, Codable {
    var id: String
    var kind: TabKind
    /// Last known title. Agent tabs refresh theirs from the graph, see `AppState.title(of:)`.
    var title: String
    var icon: String

    init(kind: TabKind, title: String? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
        self.title = title ?? Self.defaultTitle(kind)
        icon = Self.icon(kind)
    }

    /// Panes and Welcome stay put, so a window always has a tab.
    var closable: Bool { kind != .panes && kind != .welcome }

    var isAgent: Bool { if case .agent = kind { true } else { false } }

    static func defaultTitle(_ kind: TabKind) -> String {
        switch kind {
        case .welcome: "Welcome"
        case .panes: "Panes"
        case .station: "Station"
        case .orchestrator: "Orchestrator"
        case .activity: "Activity"
        case .agent(.node(let id)): id
        case .agent(.session(_, let name)): name
        case .dev(.orchestratorDemo): "Canvas demo"
        case .dev(.mascotGallery): "Patch"
        }
    }

    static func icon(_ kind: TabKind) -> String {
        switch kind {
        case .welcome: "house"
        case .panes: "rectangle.split.2x1"
        case .station: "square.grid.3x3"
        case .orchestrator: "point.3.connected.trianglepath.dotted"
        case .activity: "waveform.path.ecg"
        case .agent: "terminal"
        case .dev: "hammer"
        }
    }

    /// The mode the window is in while this tab shows.
    var mode: AppMode {
        switch kind {
        case .welcome: .welcome
        case .panes: .panes
        case .station: .station
        case .orchestrator: .orchestrator
        case .activity: .activity
        case .agent: .agent
        case .dev: .dev
        }
    }
}

/// A project that is open but not in front: everything AppState holds for it, parked
/// so switching back is instant. Terminal clients keep running and keep scrollback.
@MainActor
final class ProjectWorkspace {
    let project: Project
    var panes: [PaneSession] = []
    var focusedID: UUID?
    var maximizedID: UUID?
    var stateWatchers: [UUID: AnyCancellable] = [:]
    var orchestratorPane: PaneSession?
    var orch: ProjectOrchestrator?
    var orchestratorInfo: OrchestratorState?
    var nodePositions: [String: CGPoint] = [:]
    var finishedNodes: [AgentNode] = []
    var tabs: [Tab] = []
    var selectedTabID = ""
    var previousTabID: String?
    var agentPanes: [String: PaneSession] = [:]

    init(project: Project) { self.project = project }
}

extension AppState {
    // MARK: Selecting

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    /// Shows the tab: mode follows, the tab's terminal (if any) gets the keyboard.
    func select(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if selectedTabID != id {
            previousTabID = selectedTabID
            selectedTabID = id
        }
        if mode != tab.mode { mode = tab.mode }
        prepare(tab)
        focusSelectedTab()
        saveLayout()
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    /// Cmd+Shift+[ and ], wrapping around.
    func selectAdjacentTab(_ delta: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs.count > 1 else { return }
        select(index: (i + delta + tabs.count) % tabs.count)
    }

    /// Back to the tab shown before this one, else the first.
    func selectPrevious() {
        if let p = previousTabID, p != selectedTabID, tabs.contains(where: { $0.id == p }) {
            select(p)
        } else if let first = tabs.first, first.id != selectedTabID {
            select(first.id)
        }
    }

    // MARK: Opening

    /// Opens (or focuses, if already open) a tab of this kind in the current project.
    func open(_ kind: TabKind) {
        switch kind {
        case .agent(let ref):
            openAgent(ref)
            return
        case .welcome:
            if project != nil { return }
        case .panes, .orchestrator:
            guard project != nil else {
                flash("Open a project first")
                return
            }
        default: break
        }
        if let t = tabs.first(where: { $0.kind == kind }) {
            select(t.id)
            return
        }
        let tab = Tab(kind: kind)
        tabs.append(tab)
        select(tab.id)
    }

    /// Opens an agent's chat as a tab, or jumps to it if it's already open.
    func openAgent(_ ref: AgentRef) {
        let ref = canonical(ref)
        orch?.answering = nil
        if let t = tabs.first(where: { tab in
            if case .agent(let r) = tab.kind { return r == ref || canonical(r) == ref }
            return false
        }) {
            select(t.id)
            return
        }
        switch ref {
        case .node(let id):
            guard orch?.shown.nodes[id] != nil else {
                flash("That agent is gone")
                return
            }
        case .session(let h, let name):
            guard host(h) != nil, SessionName.isValid(name) else { return }
        }
        var tab = Tab(kind: .agent(ref))
        tab.title = title(of: tab)
        tabs.append(tab)
        select(tab.id)
    }

    /// One form per agent, so the same terminal never opens twice: a worker node becomes
    /// its tmux session, and the orchestrator's session becomes the orchestrator node
    /// (which follows it to whichever host it runs on).
    func canonical(_ ref: AgentRef) -> AgentRef {
        switch ref {
        case .node(let id):
            if let n = orch?.shown.nodes[id], n.kind == .worker, let s = n.tmuxSession {
                return .session(host: n.hostId, name: s)
            }
            return ref
        case .session(let h, let name):
            if let o = orchestratorPane, o.host.id == h, o.session == name { return .node(AgentGraph.orchestratorID) }
            if let n = orch?.graph.orchestrator, n.hostId == h, n.tmuxSession == name { return .node(AgentGraph.orchestratorID) }
            return ref
        }
    }

    // MARK: Closing and moving

    /// Closes a tab and its attached terminal. Panes and Welcome can't be closed.
    func closeTab(_ id: String? = nil) {
        let id = id ?? selectedTabID
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].closable else { return }
        let tab = tabs.remove(at: i)
        agentPanes.removeValue(forKey: id)?.close()
        if tab.kind == .agent(.node(AgentGraph.orchestratorID)) { orch?.answering = nil }
        if selectedTabID == id {
            if let p = previousTabID, tabs.contains(where: { $0.id == p }) {
                select(p)
            } else {
                select(tabs[min(i, tabs.count - 1)].id)
            }
        } else {
            saveLayout()
        }
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(0, to), tabs.count))
        saveLayout()
    }

    /// Drops the dragged tab where `target` is.
    func moveTab(id: String, before target: String) {
        guard let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        moveTab(from: from, to: to)
    }

    // MARK: Agent tabs

    /// Agent tab title: the node's name if the graph knows it, else the session's task.
    func title(of tab: Tab) -> String {
        guard case .agent(let ref) = tab.kind else { return tab.title }
        switch ref {
        case .node(let id):
            return orch?.shown.nodes[id]?.name ?? tab.title
        case .session(let h, let name):
            if let n = orch?.shown.nodes.values.first(where: { $0.hostId == h && $0.tmuxSession == name }) { return n.name }
            return CASessionName.parse(name, hostIDs: hosts.map(\.id))?.task ?? name
        }
    }

    /// Host whose accent an agent tab wears.
    func hostID(of ref: AgentRef) -> String? {
        switch ref {
        case .node(let id):
            if id == AgentGraph.orchestratorID, let o = orchestratorPane { return o.host.id }
            return orch?.shown.nodes[id]?.hostId
        case .session(let h, _): return h
        }
    }

    /// The live terminal an agent tab shows, if it has one: the orchestrator's own pane,
    /// or the tab's attached session. Built-in subagents have none.
    func agentTerminal(_ tab: Tab) -> PaneSession? {
        guard case .agent(let ref) = tab.kind else { return nil }
        if case .node(let id) = ref {
            if id == AgentGraph.orchestratorID { return orchestratorPane }
            return nil
        }
        return agentPanes[tab.id]
    }

    /// The selected agent tab's terminal.
    var selectedAgentTerminal: PaneSession? { selectedTab.flatMap(agentTerminal) }

    /// The open agent tab pane attached to this session, if any.
    func agentPane(host: String, session: String) -> PaneSession? {
        guard let tab = tabs.first(where: { $0.kind == .agent(.session(host: host, name: session)) }) else { return nil }
        return agentPanes[tab.id]
    }

    /// Attaches a session tab's terminal the first time the tab shows. Never creates the session.
    private func prepare(_ tab: Tab) {
        guard case .agent(.session(let h, let name)) = tab.kind, agentPanes[tab.id] == nil,
              let host = host(h), let pane = attachPane(host: host, session: name) else { return }
        agentPanes[tab.id] = pane
    }

    /// Gives the selected tab's terminal the keyboard, and takes it from a hidden one.
    func focusSelectedTab() {
        guard let tab = selectedTab else { return }
        let target: PaneSession? = tab.kind == .panes ? focused : agentTerminal(tab)
        if let win = window, let t = win.firstResponder as? PaneTerminalView, t !== target?.terminal {
            win.makeFirstResponder(nil)
        }
        guard let target else { return }
        if tab.kind == .panes {
            focus(target.id)
        } else {
            focusTerminal(target, tab: tab.id)
        }
    }

    /// The view may not be in the window yet, and a relayout as the attach goes live can
    /// take focus away, so keep at it until the terminal holds focus and is past
    /// connecting (about 4 s at most), while the same tab is selected.
    private func focusTerminal(_ pane: PaneSession, tab id: String, attempt: Int = 0) {
        guard attempt < 80 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self] in
            guard let self, self.selectedTabID == id else { return }
            let t = pane.terminal
            if let win = t.window, win.firstResponder !== t { win.makeFirstResponder(t) }
            if t.window?.firstResponder !== t || pane.state == .connecting {
                self.focusTerminal(pane, tab: id, attempt: attempt + 1)
            }
        }
    }

    // MARK: Saved tabs

    /// Tabs from a saved project: agent tabs on unknown hosts and dev tabs dropped,
    /// Panes always there. Older files only had a mode, which maps to a tab.
    func restoreTabs(_ state: ProjectState) {
        var list = (state.tabs ?? []).filter { tab in
            switch tab.kind {
            case .welcome, .dev: return false
            case .agent(.session(let h, let name)): return host(h) != nil && SessionName.isValid(name)
            default: return true
            }
        }
        var seen: Set<TabKind> = []
        list = list.filter { seen.insert($0.kind).inserted }
        if !list.contains(where: { $0.kind == .panes }) { list.insert(Tab(kind: .panes), at: 0) }
        for i in list.indices { list[i].icon = Tab.icon(list[i].kind) }
        var selected = state.selectedTab.flatMap { id in list.first { $0.id == id } }
        if selected == nil, state.tabs == nil, let m = state.mode, m == "orchestrator" || m == "station" {
            let tab = Tab(kind: m == "station" ? .station : .orchestrator)
            list.append(tab)
            selected = tab
        }
        tabs = list
        previousTabID = nil
        selectedTabID = (selected ?? list[0]).id
        mode = (selected ?? list[0]).mode
    }

    /// What gets saved: no dev tabs, titles current.
    var savedTabs: (tabs: [Tab], selected: String?) {
        let list = tabs.filter { if case .dev = $0.kind { false } else { $0.kind != .welcome } }
            .map { t -> Tab in
                var t = t
                t.title = title(of: t)
                return t
            }
        let sel = list.contains { $0.id == selectedTabID } ? selectedTabID : list.first?.id
        return (list, sel)
    }

    // MARK: Workspaces

    /// Parks the open project with its terminals still running. The no project
    /// workspace (Welcome, maybe a station or a session tab) is just closed.
    func stashWorkspace() {
        guard let project else {
            for p in agentPanes.values { p.close() }
            agentPanes = [:]
            return
        }
        saveLayout()
        stopDemo()
        orch?.relay = nil
        if let o = orch {
            o.saveTask?.cancel()
            o.watchers = []
            if o.monitorFast, mode != .station { monitor?.setActive(false) }
            o.monitorFast = false
        }
        if broadcast { setBroadcast(false, quiet: true) }
        let ws = ProjectWorkspace(project: project)
        ws.panes = panes
        ws.focusedID = focusedID
        ws.maximizedID = maximizedID
        ws.stateWatchers = stateWatchers
        ws.orchestratorPane = orchestratorPane
        ws.orch = orch
        ws.orchestratorInfo = orchestratorInfo
        ws.nodePositions = nodePositions
        ws.finishedNodes = finishedNodes
        ws.tabs = tabs
        ws.selectedTabID = selectedTabID
        ws.previousTabID = previousTabID
        ws.agentPanes = agentPanes
        workspaces.removeAll { $0.project.path == project.path }
        workspaces.append(ws)
    }

    /// Brings a parked project back to the front, terminals and all.
    func restoreWorkspace(_ ws: ProjectWorkspace) {
        workspaces.removeAll { $0 === ws }
        isRestoring = true
        project = ws.project
        panes = ws.panes
        focusedID = ws.focusedID
        maximizedID = ws.maximizedID
        stateWatchers = ws.stateWatchers
        orchestratorInfo = ws.orchestratorInfo
        nodePositions = ws.nodePositions
        finishedNodes = ws.finishedNodes
        agentPanes = ws.agentPanes
        orch = ws.orch
        orchestratorPane = ws.orchestratorPane
        tabs = ws.tabs
        previousTabID = ws.previousTabID
        selectedTabID = ws.selectedTabID
        mode = selectedTab?.mode ?? .panes
        isRestoring = false
        for pane in panes { wire(pane) }
        if let o = orch { wireOrchestrator(o) }
        store.lastProjectPath = ws.project.path
        store.noteOpened(ws.project)
        if let t = selectedTab { select(t.id) }
    }

    /// Empties the front without saving: what's left is the no project Welcome tab.
    func resetToWelcome() {
        isRestoring = true
        project = nil
        panes = []
        stateWatchers = [:]
        focusedID = nil
        maximizedID = nil
        orch = nil
        orchestratorPane = nil
        orchestratorInfo = nil
        nodePositions = [:]
        finishedNodes = []
        agentPanes = [:]
        let welcome = Tab(kind: .welcome)
        tabs = [welcome]
        previousTabID = nil
        selectedTabID = welcome.id
        mode = .welcome
        isRestoring = false
    }

    /// Paths of every open project, the front one included, in the order they were opened.
    var openProjects: [Project] {
        workspaces.map(\.project) + (project.map { [$0] } ?? [])
    }

    /// On quit: saves and closes every parked project.
    func closeParkedWorkspaces() {
        for ws in workspaces {
            store.saveState(projectState(ws), for: ws.project)
            if let o = ws.orch {
                o.controller.stop()
                o.demoTimer?.invalidate()
                o.saveTask?.cancel()
                for p in o.workerPanes.values { p.close() }
            }
            ws.orchestratorPane?.close()
            for p in ws.panes { p.close() }
            for p in ws.agentPanes.values { p.close() }
        }
        workspaces = []
    }

    private func projectState(_ ws: ProjectWorkspace) -> ProjectState {
        var finished = ws.finishedNodes
        if let g = ws.orch?.graph { finished = g.finished.compactMap { g.nodes[$0] } }
        var info = ws.orchestratorInfo
        if let o = ws.orchestratorPane { info = OrchestratorState(hostId: o.host.id, session: o.session, enabled: true) }
        let g = ws.orch?.graph
        let workers = g.map { g in
            g.nodes.values.filter { $0.kind == .worker && !g.finished.contains($0.id) }.sorted { $0.startedAt < $1.startedAt }
        } ?? []
        let tabs = ws.tabs.filter { if case .dev = $0.kind { false } else { true } }
        return ProjectState(
            panes: ws.panes.map { SavedPane(hostId: $0.host.id, mode: $0.mode, session: $0.session) },
            mode: tabs.first { $0.id == ws.selectedTabID }?.mode.rawValue,
            orchestrator: info,
            nodePositions: g.map { g in ws.nodePositions.filter { g.nodes[$0.key] != nil } } ?? ws.nodePositions,
            finishedNodes: finished.isEmpty ? nil : finished,
            orchestratorOn: ws.orch?.enabled,
            workerNodes: workers.isEmpty ? nil : workers,
            tabs: tabs,
            selectedTab: tabs.contains { $0.id == ws.selectedTabID } ? ws.selectedTabID : tabs.first?.id)
    }
}
