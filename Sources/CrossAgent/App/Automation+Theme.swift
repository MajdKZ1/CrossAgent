import AppKit
import SwiftUI

/// Theme automation.
///
///     {"cmd":"theme","name":"Mono"}
///     {"cmd":"theme","out":"/tmp/theme.json"}     current, all names and problems
///     {"cmd":"theme","reload":true}
///     {"cmd":"theme","settingsOut":"/tmp/settings.png"}    renders the Themes settings pane
extension Automation {
    func handleTheme(_ name: String, _ cmd: [String: Any]) -> Bool {
        guard name == "theme" else { return false }
        let store = ThemeStore.shared
        if cmd["reload"] as? Bool == true { store.reload() }
        if let theme = cmd["name"] as? String { store.select(name: theme) }
        if let out = cmd["out"] as? String {
            // Per terminal: frames SwiftTerm has drawn, and whether its window is on screen.
            let terminals = Theme.liveTerminals.map { t -> [String: Any] in
                ["frames": t.diagnostics.frames, "bg": t.nativeBackgroundColor.description,
                 "visible": t.window?.occlusionState.contains(.visible) ?? false]
            }
            let state: [String: Any] = ["current": store.current.name, "all": store.all.map(\.name),
                                        "problems": store.problems, "terminals": terminals]
            let data = (try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            try? data.write(to: URL(fileURLWithPath: out))
        }
        if let out = cmd["settingsOut"] as? String { writeSettings(to: out) }
        return true
    }

    /// Renders the Themes settings pane offscreen, so it can be checked without opening Settings.
    private func writeSettings(to path: String) {
        let view = NSHostingView(rootView: ThemeSettingsView().frame(width: 560, height: 380))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 380)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            window.close()
        }
    }
}
