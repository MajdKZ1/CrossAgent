import AppKit
import SwiftUI

@main
struct CrossAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Project windows are plain NSWindows made by ProjectWindows, one per project.
        // Everything else is a tab in one of them, or a popover.
        Settings { ThemeSettingsView() }
            .commands {
                PaneCommands(windows: .shared)
                CommandGroup(after: .toolbar) { Menu("Theme") { ThemeMenuItems() } }
            }
    }
}

/// Menu items for discoverability. They act on the key project window. The keys
/// themselves are handled by `Shortcuts`, so every action goes through `item`, which
/// skips a key press already handled there.
struct PaneCommands: Commands {
    @ObservedObject var windows: ProjectWindows

    private func item(_ title: String, _ action: @escaping (AppState) -> Void) -> Button<Text> {
        Button(title) {
            MainActor.assumeIsolated {
                if !Shortcuts.currentEventWasHandled, let app = windows.current { action(app) }
            }
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("New Pane") { $0.openNewPanePopover() }
                .keyboardShortcut("t")
            Button("Open Project…") {
                MainActor.assumeIsolated { if !Shortcuts.currentEventWasHandled { windows.presentOpenPanel() } }
            }
            .keyboardShortcut("o")
            Menu("Open Recent") { RecentProjectsMenu(windows: windows) }
            Divider()
            item("Close Tab") { app in if app.mode == .panes { app.close() } else { app.closeTab() } }
                .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            item("Close Project") { $0.leaveProject() }
        }
        CommandGroup(before: .sidebar) {
            item("Panes") { $0.open(.panes) }
            item("Station") { $0.toggleMode(.station) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            item("Orchestrator") { app in if app.project != nil { app.toggleMode(.orchestrator) } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            item("Activity") { $0.open(.activity) }
            item("Sessions") { $0.open(.sessions) }
            Divider()
            item("Next Tab") { $0.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            item("Previous Tab") { $0.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1..<10) { n in
                item(n == 9 ? "Last Tab" : "Tab \(n)") { $0.selectTab(shortcut: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
            Divider()
        }
        CommandMenu("Orchestrator") {
            if let app = windows.current { OrchestratorMenu(app: app) }
        }
        CommandMenu("Panes") {
            item("Next Pane") { $0.moveFocus(1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            item("Previous Pane") { $0.moveFocus(-1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            item("Maximize / Restore") { $0.toggleMaximize() }
                .keyboardShortcut(.return)
            Divider()
            item("Broadcast") { $0.toggleBroadcast() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            item("Relay Selection") { $0.openRelayPicker() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { n in
                item("Focus Pane \(n)") { $0.focus(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .control)
            }
        }
    }
}

/// File > Open Recent. Recents are not published; ProjectWindows publishes when they change.
struct RecentProjectsMenu: View {
    @ObservedObject var windows: ProjectWindows

    var body: some View {
        let recents = windows.store.recents()
        ForEach(recents) { r in
            Button(r.name) { windows.open(r.url) }
        }
        if !recents.isEmpty { Divider() }
        Button("Clear Menu") {
            for r in recents { windows.store.removeRecent(path: r.path) }
            windows.recentsChanged()
        }
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
    #if DEBUG
    private var automation: Automation?
    #endif
    private var shortcuts: Shortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run) instead of a bundle.
        NSApp.setActivationPolicy(.regular)
        if let icon = Self.bundledIcon() { NSApp.applicationIconImage = icon }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // CROSSAGENT_NO_ACTIVATE=1 keeps a test launch from stealing focus.
        if ProcessInfo.processInfo.environment["CROSSAGENT_NO_ACTIVATE"] != "1" { NSApp.activate(ignoringOtherApps: true) }
        let windows = ProjectWindows.shared
        // Debug builds only: release builds carry no remote control channel at all.
        #if DEBUG
        if Automation.enabled { automation = Automation(windows: windows) }
        #endif
        MascotGallery.writeSnapshotsIfRequested()
        shortcuts = Shortcuts(windows: windows)
        windows.restore()
        // With no other scene SwiftUI opens Settings at launch. Only Cmd+, should.
        closeSettings()
        DispatchQueue.main.async { self.closeSettings() }
        // Dev views open as tabs in the front window, never as windows of their own.
        // The demo opens last so it's the one showing: its pointer checks need the canvas up.
        if MascotGallery.isRequested { windows.current?.open(.dev(.mascotGallery)) }
        if OrchestratorDemo.isRequested { windows.current?.open(.dev(.orchestratorDemo)) }
    }

    /// Runs before any window closes for the quit, so the open list is still whole.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ProjectWindows.shared.prepareToQuit()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProjectWindows.shared.monitor.stop()
        SyncMonitor.shared.stop()
        // Synchronous, so no ssh sampler is left running on the PC after quit.
        ActivityMonitor.shared.shutdown()
        EventFollower.shutdownAll()
        SessionFeed.shutdownAll()
        ProjectWindows.shared.saveAndCloseAll()
    }

    /// Closing the last window quits. Closing one of several just closes that project.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A click on the Dock icon with every window closed (Settings was up) brings back the welcome window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, ProjectWindows.shared.states.isEmpty { ProjectWindows.shared.showWelcome() }
        return true
    }

    private func closeSettings() {
        for w in NSApp.windows where w.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" { w.close() }
    }

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
