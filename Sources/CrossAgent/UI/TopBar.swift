import AppKit
import SwiftUI

/// The one row at the top of the window: traffic lights, the project switcher, the
/// tabs, then agent chips, sync, activity and the new button on the right.
struct TopBar: View {
    @EnvironmentObject private var app: AppState
    @State private var width: CGFloat = 1200

    var body: some View {
        HStack(spacing: 8) {
            ProjectTitle()
                .fixedSize()
            TabStrip()
                .layoutPriority(1)
            Spacer(minLength: 8)
            if width >= 1000, let o = app.orch { AgentChips(orch: o).fixedSize() }
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
        .padding(.leading, Palette.trafficLightInset)
        .padding(.trailing, 10)
        .frame(height: Palette.topBarHeight)
        .background(WindowDragArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Tabs

/// Tabs come and go instantly: a removal transition would leave a gap behind while
/// the window is covered and no frames run.
struct TabStrip: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(app.tabs.enumerated()), id: \.element.id) { i, tab in
                TabItem(tab: tab, index: i, selected: tab.id == app.selectedTabID)
            }
        }
    }
}

private struct TabItem: View {
    @EnvironmentObject private var app: AppState
    var tab: Tab
    var index: Int
    var selected: Bool
    @State private var hovering = false
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(app.title(of: tab))
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Palette.text : Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            if tab.closable {
                Spacer(minLength: 0)
                Button { app.closeTab(tab.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(TabCloseStyle())
                    .opacity(hovering ? 1 : 0)
                    .help("Close tab (⌘W)")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, tab.closable ? 4 : 10)
        .modifier(TabWidth(flexible: tab.closable))
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.white.opacity(0.09) : (hovering ? Palette.chip : .clear)))
        .overlay(alignment: .leading) {
            if dropTarget { Capsule().fill(Palette.primary).frame(width: 2, height: 16).offset(x: -2) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.select(tab.id) }
        .overlay(MiddleClick { app.closeTab(tab.id) })
        .help(index < 9 ? "\(app.title(of: tab))  ⌘\(index + 1)" : app.title(of: tab))
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

/// Fixed tabs (Panes, Welcome) hug their label; the rest share the room up to a cap.
private struct TabWidth: ViewModifier {
    var flexible: Bool

    func body(content: Content) -> some View {
        if flexible {
            content.frame(minWidth: 60, idealWidth: 130, maxWidth: 140, alignment: .leading)
        } else {
            content.fixedSize(horizontal: true, vertical: false)
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
