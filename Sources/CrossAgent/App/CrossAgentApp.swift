import AppKit
import SwiftUI

@main
struct CrossAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window. Everything else is a tab in it, or a popover.
        Window("CrossAgent", id: "main") {
            ContentView()
                .environmentObject(appDelegate.app)
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { PaneCommands(app: appDelegate.app) }
        Settings { SettingsSlot() }
    }
}

/// Placeholder for the Settings window's content.
struct SettingsSlot: View {
    var body: some View {
        Text("Nothing to set yet")
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(width: 360, height: 160)
    }
}

/// Menu items for discoverability. The keys themselves are handled by `Shortcuts`,
/// so every action goes through `item`, which skips a key press already handled there.
struct PaneCommands: Commands {
    let app: AppState

    private func item(_ title: String, _ action: @escaping () -> Void) -> Button<Text> {
        Button(title) {
            MainActor.assumeIsolated { if !Shortcuts.currentEventWasHandled { action() } }
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("New Pane") { app.openNewPanePopover() }
                .keyboardShortcut("t")
            item("Open Project…") { app.presentOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") { RecentProjectsMenu(app: app) }
            Divider()
            item("Close Tab") { if app.mode == .panes { app.close() } else { app.closeTab() } }
                .keyboardShortcut("w")
            Button("Close Project") { app.leaveProject() }
        }
        CommandGroup(before: .sidebar) {
            Button("Panes") { app.open(.panes) }
            item("Station") { app.toggleMode(.station) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            item("Orchestrator") { if app.project != nil { app.toggleMode(.orchestrator) } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Activity") { app.open(.activity) }
            Divider()
            item("Next Tab") { app.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            item("Previous Tab") { app.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1..<10) { n in
                item("Tab \(n)") { app.select(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
            Divider()
        }
        CommandMenu("Orchestrator") { OrchestratorMenu(app: app) }
        CommandMenu("Panes") {
            item("Next Pane") { app.moveFocus(1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            item("Previous Pane") { app.moveFocus(-1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            item("Maximize / Restore") { app.toggleMaximize() }
                .keyboardShortcut(.return)
            Divider()
            item("Broadcast") { app.toggleBroadcast() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            item("Relay Selection") { app.openRelayPicker() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { n in
                item("Focus Pane \(n)") { app.focus(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .control)
            }
        }
    }
}

/// File > Open Recent. A view so it follows the app's changes (recents are not published,
/// but the app publishes whenever they change).
struct RecentProjectsMenu: View {
    @ObservedObject var app: AppState

    var body: some View {
        let recents = app.recentProjects
        ForEach(recents) { r in
            Button(r.name) { app.switchProject(r.url) }
        }
        if !recents.isEmpty { Divider() }
        Button("Clear Menu") { app.clearRecents() }
            .disabled(recents.isEmpty)
    }
}

/// The Orchestrator menu. A view so it follows the open project.
struct OrchestratorMenu: View {
    @ObservedObject var app: AppState
    @AppStorage("mascotHidden") private var mascotHidden = false

    var body: some View {
        let on = app.orch?.enabled == true
        Button("Clear Finished Agents") { app.clearFinishedAgents() }
            .disabled(app.orch == nil)
        Toggle("Show Mascot", isOn: Binding(get: { !mascotHidden }, set: { mascotHidden = !$0 }))
        Divider()
        Button("Turn Off Orchestrator for This Project") { app.turnOffOrchestrator() }
            .disabled(!on)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppState()
    private var automation: Automation?
    private var shortcuts: Shortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run) instead of a bundle.
        NSApp.setActivationPolicy(.regular)
        if let icon = Self.bundledIcon() { NSApp.applicationIconImage = icon }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSWindow.allowsAutomaticWindowTabbing = false
        // CROSSAGENT_NO_ACTIVATE=1 keeps a test launch from stealing focus.
        if ProcessInfo.processInfo.environment["CROSSAGENT_NO_ACTIVATE"] != "1" { NSApp.activate(ignoringOtherApps: true) }
        if Automation.enabled { automation = Automation(app: app) }
        MascotGallery.writeSnapshotsIfRequested()
        shortcuts = Shortcuts(app: app)
        app.warmUpConnections()
        let monitor = TmuxMonitor(hosts: app.hosts)
        app.monitor = monitor
        monitor.start()
        app.sync.start { [weak app] in app?.window }
        app.restoreLastProject()
        // Dev views open as tabs in the window, never as windows of their own.
        // The demo opens last so it's the one showing: its pointer checks need the canvas up.
        if MascotGallery.isRequested { app.open(.dev(.mascotGallery)) }
        if OrchestratorDemo.isRequested { app.open(.dev(.orchestratorDemo)) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.monitor?.stop()
        app.sync.stop()
        app.saveLayout()
        app.tearDownOrchestrator()
        app.closeParkedWorkspaces()
        for pane in app.panes { pane.close() }
        for pane in app.agentPanes.values { pane.close() }
        app.orchestratorPane?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// AppIcon.icns from the .app, or from the SwiftPM resource bundle next to a bare
    /// binary (swift run). Looked up by hand since Bundle.module traps when it's missing.
    static func bundledIcon() -> NSImage? {
        let resources = Bundle.main.executableURL.flatMap {
            Bundle(url: $0.deletingLastPathComponent().appendingPathComponent("CrossAgent_CrossAgent.bundle"))
        }
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? resources?.url(forResource: "AppIcon", withExtension: "icns")
        return url.flatMap(NSImage.init(contentsOf:))
    }
}
