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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppState()
    private var automation: Automation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run) instead of a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Automation.enabled { automation = Automation(app: app) }
        app.warmUpConnections()
        app.restoreLayout()
        if app.panes.isEmpty { app.newPane(hostID: "mac", mode: .shell) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.saveLayout()
        for pane in app.panes { pane.close() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
