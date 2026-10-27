import AppKit
import SwiftUI

struct TopBar: View {
    @EnvironmentObject private var app: AppState
    @State private var width: CGFloat = 1200

    var body: some View {
        HStack(spacing: 10) {
            if let project = app.project {
                ProjectTitle(project: project)
                ProjectPath(project: project, sync: app.sync)
            } else {
                Text("CrossAgent")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.trailing, 4)
            }
            if width >= 1000 {
                ForEach(app.hosts) { host in HostChip(host: host) }
            }
            Spacer(minLength: 8)

            if app.project != nil {
                ModeSwitch(compact: width < 760).fixedSize()
            } else {
                Button { app.toggleMode(.station) } label: {
                    Label("Station", systemImage: "square.grid.3x3").labelStyle(.titleAndIcon)
                }
                .buttonStyle(ChromeButtonStyle(active: app.showStation, tint: Palette.text))
                .help("Viewing station (⌘⇧V)")
            }

            SyncIndicator(sync: app.sync)

            if app.project != nil {
                Button { app.showNewPane.toggle() } label: {
                    Label("New pane", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(ChromeButtonStyle())
                .help("New pane (⌘T)")
                .fixedSize()
                .popover(isPresented: $app.showNewPane, arrowEdge: .bottom) {
                    NewPanePopover().environmentObject(app)
                }
            }

            if app.project != nil || !app.panes.isEmpty {
                Button { app.toggleBroadcast() } label: {
                    Label("Broadcast", systemImage: "dot.radiowaves.left.and.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(ChromeButtonStyle(active: app.broadcast, tint: Palette.broadcast))
                .help("Type into every live pane (⌘⇧B)")
                .fixedSize()
            }
        }
        .padding(.leading, Palette.trafficLightInset)
        .padding(.trailing, 10)
        .frame(height: Palette.topBarHeight)
        .background(WindowDragArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Project name with a chevron that opens the project switcher.
struct ProjectTitle: View {
    @EnvironmentObject private var app: AppState
    var project: Project
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(project.name)
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
        .help("Switch project")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProjectSwitcher(close: { open = false }).environmentObject(app)
        }
    }
}

struct ProjectSwitcher: View {
    @EnvironmentObject private var app: AppState
    var close: () -> Void

    var body: some View {
        let recents = app.recentProjects
        VStack(alignment: .leading, spacing: 2) {
            Text("PROJECTS")
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Palette.faint)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(recents.prefix(8)) { r in
                row {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
                            Text(tildePath(r.path))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.faint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        if r.path == app.project?.path {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                        }
                    }
                } action: { app.switchProject(r.url) }
            }
            Divider().padding(.vertical, 4)
            row { Label("Open folder…", systemImage: "folder").font(.system(size: 12)) } action: { app.presentOpenPanel() }
            row { Label("Close project", systemImage: "xmark.circle").font(.system(size: 12)) } action: { app.leaveProject() }
        }
        .padding(8)
        .frame(width: 280)
    }

    private func row<L: View>(@ViewBuilder _ label: () -> L, action: @escaping () -> Void) -> some View {
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

/// The project folder in ~ form, click to reveal in Finder. While Mutagen syncs the
/// project, the PC copy's path follows in the PC accent.
struct ProjectPath: View {
    @EnvironmentObject private var app: AppState
    var project: Project
    @ObservedObject var sync: SyncMonitor

    var body: some View {
        HStack(spacing: 8) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([project.url]) } label: {
                Text(tildePath(project.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(project.path)
            if app.projectSyncActive, let pc = app.hosts.first(where: { !$0.isLocal }) {
                Text("\(pc.id): ~/\(project.pcRelativePath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.accent(pc).opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Synced to ~/\(project.pcRelativePath) on \(pc.name)")
            }
        }
    }
}

/// Panes, Station, Orchestrator.
struct ModeSwitch: View {
    @EnvironmentObject private var app: AppState
    /// Icons only, for narrow windows.
    var compact = false
    @Namespace private var pill

    private struct Item {
        var mode: AppMode, title: String, icon: String, help: String
    }

    private static let items = [
        Item(mode: .panes, title: "Panes", icon: "rectangle.split.2x1", help: "Panes"),
        Item(mode: .station, title: "Station", icon: "square.grid.3x3", help: "Viewing station (⌘⇧V)"),
        Item(mode: .orchestrator, title: "Orchestrator", icon: "point.3.connected.trianglepath.dotted",
             help: "Orchestrator (⌘⇧O)"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.items, id: \.mode) { item in
                let m = item.mode, title = item.title, icon = item.icon, help = item.help
                let on = app.mode == m
                Button { app.mode = m } label: {
                    Label(title, systemImage: icon)
                        .labelStyle(LabelStyleChoice(compact: compact))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(on ? Palette.text : Palette.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.1))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.chip))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: app.mode)
    }
}

private struct LabelStyleChoice: LabelStyle {
    var compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 5) { configuration.icon; configuration.title }
        }
    }
}

struct HostChip: View {
    @EnvironmentObject private var app: AppState
    var host: Host

    var body: some View {
        // paneStateVersion is read so the count refreshes when a pane connects or exits.
        let _ = app.paneStateVersion
        let live = app.liveCount(host: host)
        HStack(spacing: 6) {
            Dot(color: live > 0 ? Palette.accent(host) : Palette.faint, size: 6)
            Text(host.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.text.opacity(0.85))
            Text("\(live)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(live > 0 ? Palette.text.opacity(0.7) : Palette.faint)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Palette.chip))
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
        .help("\(live) live pane\(live == 1 ? "" : "s") on \(host.name)")
    }
}
