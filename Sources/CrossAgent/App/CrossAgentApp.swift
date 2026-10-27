import AppKit
import SwiftUI

@main
struct CrossAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CrossAgent") {
            ContentView()
                .environmentObject(appDelegate.app)
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { PaneCommands(app: appDelegate.app) }
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
            item("New Pane") { app.showNewPane = true }
                .keyboardShortcut("t")
            item("Close Pane") { app.close() }
                .keyboardShortcut("w")
        }
        CommandMenu("Panes") {
            item("Next Pane") { app.moveFocus(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            item("Previous Pane") { app.moveFocus(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            item("Maximize / Restore") { app.toggleMaximize() }
                .keyboardShortcut(.return)
            Divider()
            item("Broadcast") { app.toggleBroadcast() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            item("Relay Selection") { app.openRelayPicker() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            item("Viewing Station") { app.showStation.toggle() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { n in
                item("Focus Pane \(n)") { app.focus(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }
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
        NSApp.activate(ignoringOtherApps: true)
        if Automation.enabled { automation = Automation(app: app) }
        OrchestratorDemo.openIfRequested()
        MascotGallery.openIfRequested()
        shortcuts = Shortcuts(app: app)
        app.warmUpConnections()
        let monitor = TmuxMonitor(hosts: app.hosts)
        app.monitor = monitor
        monitor.start()
        app.sync.start { [weak app] in app?.window }
        app.restoreLayout()
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.monitor?.stop()
        app.sync.stop()
        app.saveLayout()
        for pane in app.panes { pane.close() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// AppIcon.icns from the .app, or from the SwiftPM resource bundle next to a bare
    /// binary (swift run). Looked up by hand since Bundle.module traps when it's missing.
    private static func bundledIcon() -> NSImage? {
        let resources = Bundle.main.executableURL.flatMap {
            Bundle(url: $0.deletingLastPathComponent().appendingPathComponent("CrossAgent_CrossAgent.bundle"))
        }
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? resources?.url(forResource: "AppIcon", withExtension: "icns")
        return url.flatMap(NSImage.init(contentsOf:))
    }
}
