import AppKit
import SwiftUI

/// The one row at the top of the window: traffic lights, the project switcher, the
/// tabs, then agent chips, sync, activity and the new button on the right. The tabs
/// take whatever the fixed items leave. When those would leave less than two tabs'
/// worth, the agent chips go first, so nothing ever clips.
struct TopBar: View {
    @EnvironmentObject private var app: AppState
    @State private var titleWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    /// Last measured width of the chips, kept while they're hidden so they come back
    /// only when they'd fit (no flicker).
    @State private var chipsWidth: CGFloat = 0

    private static let spacing: CGFloat = 8
    private static let trailingPad: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            // The proposal is the window's width, whatever the content wants.
            let room = geo.size.width - Palette.trafficLightInset - Self.trailingPad - titleWidth - trailingWidth
                - Self.spacing * 2
            let showChips = room - chipsWidth - Self.spacing >= 2 * TabStrip.selectedMin
            HStack(spacing: Self.spacing) {
                ProjectTitle()
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                TabStrip()
                if showChips, let o = app.orch {
                    AgentChips(orch: o)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipsWidth = $0 }
                }
                HStack(spacing: Self.spacing) {
                    SyncIndicator(sync: app.sync)
                        .fixedSize()
                    ActivityReadout()
                        .fixedSize()
                    if app.mode == .panes && !app.panes.isEmpty {
                        Button { app.toggleBroadcast() } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                            .buttonStyle(ChromeButtonStyle(active: app.broadcast, tint: Palette.broadcast))
                            .help("Broadcast, type into every live pane (⌘⇧B)")
                            .fixedSize()
                    }
                    NewMenu()
                        .fixedSize()
                }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
            }
            .padding(.leading, Palette.trafficLightInset)
            .padding(.trailing, Self.trailingPad)
            .frame(width: geo.size.width, height: Palette.topBarHeight, alignment: .leading)
        }
        .frame(height: Palette.topBarHeight)
        .background(WindowDragArea())
    }
}

// MARK: - Tabs

/// Tabs share the room like a browser's: up to `maxWidth` each, shrinking to
/// `minWidth` with titles truncating, the selected one kept readable. Past that the
/// strip scrolls, keeping the selected tab in view. Tabs come and go instantly: a
/// removal transition would leave a gap behind while the window is covered and no
/// frames run.
struct TabStrip: View {
    @EnvironmentObject private var app: AppState

    static let minWidth: CGFloat = 76
    static let maxWidth: CGFloat = 150
    static let selectedMin: CGFloat = 112
    static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let tabs = app.tabs
            let sel = tabs.firstIndex { $0.id == app.selectedTabID }
            if let widths = Self.widths(count: tabs.count, selected: sel, available: geo.size.width) {
                HStack(spacing: Self.gap) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                        TabItem(tab: tab, index: i, count: tabs.count, selected: i == sel, width: widths[i])
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Self.gap) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                                TabItem(tab: tab, index: i, count: tabs.count, selected: i == sel,
                                        width: i == sel ? Self.selectedMin : Self.minWidth)
                                    .id(tab.id)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    // Soft ends, so a cut off tab reads as "more this way".
                    .mask(HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                    })
                    .onAppear { proxy.scrollTo(app.selectedTabID) }
                    .onChange(of: app.selectedTabID) { _, id in proxy.scrollTo(id) }
                    .onChange(of: tabs.count) { proxy.scrollTo(app.selectedTabID) }
                    .onChange(of: geo.size.width) { proxy.scrollTo(app.selectedTabID) }
                }
            }
        }
    }

    /// Each tab's width, or nil when they don't fit even at the minimum.
    static func widths(count n: Int, selected: Int?, available: CGFloat) -> [CGFloat]? {
        guard n > 0 else { return [] }
        let room = available - gap * CGFloat(n - 1)
        let even = room / CGFloat(n)
        if even >= maxWidth { return Array(repeating: maxWidth, count: n) }
        guard let selected, n > 1 else { return even >= minWidth ? Array(repeating: even, count: n) : nil }
        let mine = max(even, selectedMin)
        let others = (room - mine) / CGFloat(n - 1)
        guard others >= minWidth else { return nil }
        return (0..<n).map { $0 == selected ? mine : others }
    }
}

private struct TabItem: View {
    @EnvironmentObject private var app: AppState
    var tab: Tab
    var index: Int
    var count: Int
    var selected: Bool
    var width: CGFloat
    @State private var hovering = false
    @State private var dropTarget = false

    /// The x sits on top of the tab's end, so it never takes room from the title.
    private var showsClose: Bool { tab.closable && (hovering || selected) }

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(app.title(of: tab))
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Palette.text : Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 9)
        .padding(.trailing, showsClose ? 24 : 9)
        .frame(width: width, height: 26, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.white.opacity(0.09) : (hovering ? Palette.chip : .clear)))
        .overlay(alignment: .trailing) {
            if showsClose {
                Button { app.closeTab(tab.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(TabCloseStyle())
                    .help("Close tab (⌘W)")
                    .padding(.trailing, 5)
            }
        }
        .overlay(alignment: .leading) {
            if dropTarget { Capsule().fill(Palette.primary).frame(width: 2, height: 16).offset(x: -2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.select(tab.id) }
        .overlay(MiddleClick { app.closeTab(tab.id) })
        .help(shortcutHelp)
        .draggable(tab.id) {
            Text(app.title(of: tab))
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.15)))
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != tab.id else { return false }
            app.moveTab(id: id, before: tab.id)
            return true
        } isTargeted: { dropTarget = $0 }
    }

    /// Cmd+1..8 by position, Cmd+9 is always the last tab.
    private var shortcutHelp: String {
        let title = app.title(of: tab)
        if index == count - 1 { return "\(title)  ⌘9" }
        return index < 8 ? "\(title)  ⌘\(index + 1)" : title
    }

    @ViewBuilder private var icon: some View {
        if case .agent(let ref) = tab.kind {
            let host = app.hostID(of: ref).flatMap(app.host)
            Dot(color: host.map(Palette.accent) ?? Palette.faint, size: 6)
        } else {
            Image(systemName: tab.icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? Palette.text : Palette.muted)
        }
    }
}

private struct TabCloseStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hover { h in
            configuration.label
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(h ? Palette.text : Palette.muted)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(h ? Palette.chipHover : .clear))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Catches a middle click on top of SwiftUI content and lets every other click through.
struct MiddleClick: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> Catcher { Catcher(action: action) }
    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent, e.type == .otherMouseDown || e.type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {}
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action() }
        }
    }
}

// MARK: - New

/// New pane, or a tab that isn't open yet.
private struct NewMenu: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Menu {
            if app.project != nil {
                Button("New pane  ⌘T") { app.openNewPanePopover() }
                Divider()
                Button("Orchestrator") { app.open(.orchestrator) }
            } else {
                Button("Open project…  ⌘O") { app.presentOpenPanel() }
                Divider()
            }
            Button("Station") { app.open(.station) }
            Button("Activity") { app.open(.activity) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text.opacity(0.85))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.chip))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("New pane or tab")
        .popover(isPresented: $app.showNewPane, arrowEdge: .bottom) {
            NewPanePopover().environmentObject(app)
        }
    }
}

// MARK: - Agent chips

/// The project's busy agents, one click from their tab. Five at most, then "+n".
private struct AgentChips: View {
    @ObservedObject var orch: ProjectOrchestrator

    var body: some View {
        AgentChipList(graph: orch.shown)
    }
}

private struct AgentChipList: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var graph: AgentGraph
    private static let maxShown = 5

    var body: some View {
        let list = active
        HStack(spacing: 4) {
            ForEach(list.prefix(Self.maxShown), id: \.id) { n in chip(n) }
            if list.count > Self.maxShown {
                Menu {
                    ForEach(list.dropFirst(Self.maxShown), id: \.id) { n in
                        Button(n.name) { app.openAgent(.node(n.id)) }
                    }
                } label: {
                    Text("+\(list.count - Self.maxShown)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Capsule().fill(Palette.chip))
                        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
    }

    /// Running agents, the orchestrator first, then by start.
    private var active: [AgentNode] {
        var out: [AgentNode] = []
        if let o = graph.orchestrator, o.tmuxSession != nil { out.append(o) }
        out += graph.others.filter { n in
            if graph.finished.contains(n.id) { return false }
            switch n.state {
            case .done, .error: return false
            default: return true
            }
        }
        return out
    }

    private func chip(_ n: AgentNode) -> some View {
        let host = app.host(n.hostId)
        let asks: Bool = { if case .needsInput = n.state { true } else { false } }()
        return Button { app.openAgent(.node(n.id)) } label: {
            HStack(spacing: 5) {
                Dot(color: host.map(Palette.accent) ?? Palette.faint, size: 6)
                Text(n.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.text.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: 90, alignment: .leading)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Palette.chip))
            .overlay(Capsule().strokeBorder(asks ? Palette.warning.opacity(0.7) : Palette.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(asks ? "\(n.name) needs input" : "\(n.name) on \(host?.name ?? n.hostId)")
    }
}

// MARK: - Project switcher

/// Project name with a chevron that opens the project switcher. "CrossAgent" with no project.
struct ProjectTitle: View {
    @EnvironmentObject private var app: AppState
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(app.project?.name ?? "CrossAgent")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Hover { h in RoundedRectangle(cornerRadius: 6).fill(h || open ? Palette.chipHover : .clear) })
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.project.map { tildePath($0.path) } ?? "Open a project")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProjectSwitcher(close: { open = false }).environmentObject(app)
        }
    }
}

/// Where the open project lives, the open projects, recents, open and close.
struct ProjectSwitcher: View {
    @EnvironmentObject private var app: AppState
    var close: () -> Void

    var body: some View {
        let open = app.openProjects.reversed()
        let openPaths = Set(open.map(\.path))
        let recents = app.recentProjects.filter { !openPaths.contains($0.path) }
        VStack(alignment: .leading, spacing: 2) {
            if let p = app.project { here(p) }
            if !open.isEmpty {
                heading("OPEN")
                ForEach(Array(open), id: \.path) { p in
                    projectRow(name: p.name, path: p.path, current: p.path == app.project?.path) { app.switchProject(p.url) }
                }
            }
            if !recents.isEmpty {
                heading("RECENT")
                ForEach(recents.prefix(8)) { r in
                    projectRow(name: r.name, path: r.path, current: false) { app.switchProject(r.url) }
                }
            }
            Divider().padding(.vertical, 4)
            row(action: { app.presentOpenPanel() }) { Label("Open folder…", systemImage: "folder").font(.system(size: 12)) }
            if app.project != nil {
                row(action: { app.leaveProject() }) { Label("Close project", systemImage: "xmark.circle").font(.system(size: 12)) }
            }
        }
        .padding(8)
        .frame(width: 290)
    }

    /// The front project's folders: the Mac one (click to reveal) and the synced PC copy.
    private func here(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([p.url]) } label: {
                Text(tildePath(p.path))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            if app.projectSyncActive, let pc = app.hosts.first(where: { !$0.isLocal }) {
                Text("\(pc.id): ~/\(p.pcRelativePath)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.accent(pc).opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Synced to ~/\(p.pcRelativePath) on \(pc.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func heading(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func projectRow(name: String, path: String, current: Bool, action: @escaping () -> Void) -> some View {
        row(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
                    Text(tildePath(path))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if current {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func row<L: View>(action: @escaping () -> Void, @ViewBuilder _ label: () -> L) -> some View {
        let label = label()
        return Button {
            close()
            // Let the popover go away before the window changes under it.
            DispatchQueue.main.async(execute: action)
        } label: {
            Hover { h in
                label
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(h ? Palette.chipHover : .clear))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}
