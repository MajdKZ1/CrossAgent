import AppKit
import Combine
import Foundation

// The tab strip of a project window. Other parts of the app (canvas, station, activity,
// mascot orbs) only call `openAgent`.

/// Something that can be opened as an agent chat tab.
enum AgentRef: Hashable, Codable {
    /// A node in the current project's AgentGraph (orchestrator, subagent or worker).
    case node(String)
    /// Any tmux session on a host, opened as its live terminal.
    case session(host: String, name: String)
    /// A Claude Code session CrossAgent doesn't own a terminal for: the read only
    /// Live view of its transcript (or the transcript of an ended one).
    case claude(host: String, sessionId: String)
}

/// One tab in a project window.
enum TabKind: Hashable, Codable {
    case welcome, panes, station, orchestrator, activity, sessions
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
        case .sessions: "Sessions"
        case .agent(.node(let id)): id
        case .agent(.session(_, let name)): name
        case .agent(.claude(_, let sid)): String(sid.prefix(8))
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
        case .sessions: "list.bullet.rectangle"
        case .agent(.claude): "eye"
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
        case .sessions: .sessions
        case .agent: .agent
        case .dev: .dev
        }
    }
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
        // SwiftUI can hand focus back to a terminal while the old tab hides, so check
        // again once the switch has landed.
        DispatchQueue.main.async { [weak self] in self?.dropHiddenTerminalFocus() }
        saveLayout()
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    /// Cmd+1..8 pick by position, Cmd+9 the last tab, like a browser.
    func selectTab(shortcut n: Int) {
        if n == 8, let last = tabs.last { select(last.id) } else { select(index: n) }
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
        case .claude(let h, _):
            guard host(h) != nil else { return }
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
        case .claude:
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
        case .claude:
            return tab.title
        }
    }

    /// Host whose accent an agent tab wears.
    func hostID(of ref: AgentRef) -> String? {
        switch ref {
        case .node(let id):
            if id == AgentGraph.orchestratorID, let o = orchestratorPane { return o.host.id }
            return orch?.shown.nodes[id]?.hostId
        case .session(let h, _), .claude(let h, _): return h
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

    /// A session tab opened before its tmux session existed (say a worker that hasn't
    /// started yet) attaches again as soon as the monitor sees the session.
    func watchMonitorForAgentTabs() {
        monitorWatch = monitor?.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.retryEndedAgentTabs() }
    }

    func retryEndedAgentTabs() {
        guard let monitor else { return }
        let now = Date()
        for tab in tabs {
            guard case .agent(.session(let h, let name)) = tab.kind, let pane = agentPanes[tab.id], pane.isExited,
                  monitor.sessions[h]?.contains(where: { $0.name == name }) == true,
                  now.timeIntervalSince(agentRetryAt[tab.id] ?? .distantPast) > 5 else { continue }
            agentRetryAt[tab.id] = now
            pane.reconnect()
            if tab.id == selectedTabID { focusSelectedTab() }
        }
    }

    /// True when the selected tab shows this terminal: a pane in the grid (the
    /// maximized one if any), or the agent tab's own.
    func showsTerminal(_ t: PaneTerminalView) -> Bool {
        guard let tab = selectedTab else { return false }
        if tab.kind == .panes {
            guard let pane = panes.first(where: { $0.terminal === t }) else { return false }
            return maximizedID == nil || maximizedID == pane.id
        }
        return agentTerminal(tab)?.terminal === t
    }

    /// A terminal that isn't on screen must never take keys. Moves focus to the
    /// selected tab's terminal (or nowhere) and says whether it had to.
    @discardableResult
    func dropHiddenTerminalFocus() -> Bool {
        guard let win = window, let t = win.firstResponder as? PaneTerminalView, !showsTerminal(t) else { return false }
        win.makeFirstResponder(nil)
        guard let tab = selectedTab else { return true }
        let target = tab.kind == .panes ? focused : agentTerminal(tab)
        if let target, target.terminal.window === win, !target.terminal.isHiddenOrHasHiddenAncestor {
            win.makeFirstResponder(target.terminal)
        }
        return true
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
}
