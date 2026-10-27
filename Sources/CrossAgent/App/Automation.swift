import AppKit

/// Dev only remote control so flows can be tested without clicking.
/// Off unless CROSSAGENT_AUTOMATION=1 or `defaults write dev.crossagent automation -bool true`.
/// Send commands with scripts/automation.sh.
@MainActor
final class Automation {
    /// CROSSAGENT_AUTOMATION_ID gives an instance its own channel, so parallel test runs don't collide.
    static let notification = Notification.Name("dev.crossagent.automation"
        + (ProcessInfo.processInfo.environment["CROSSAGENT_AUTOMATION_ID"].map { ".\($0)" } ?? ""))
    private let app: AppState
    private var observer: NSObjectProtocol?

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["CROSSAGENT_AUTOMATION"] == "1"
            || UserDefaults.standard.bool(forKey: "automation")
    }

    init(app: AppState) {
        self.app = app
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notification, object: nil, queue: .main
        ) { [weak self] note in
            guard let json = note.object as? String else { return }
            MainActor.assumeIsolated { self?.handle(json) }
        }
    }

    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = cmd["cmd"] as? String else { return }
        let index = cmd["index"] as? Int
        func pane(_ i: Int?) -> PaneSession? {
            guard let i else { return app.focused }
            return app.panes.indices.contains(i) ? app.panes[i] : nil
        }
        switch name {
        case "new" where cmd["check"] as? Bool == true:
            // Same path as the new pane popover, with the folder check on ssh hosts.
            app.requestPane(hostID: cmd["host"] as? String ?? app.lastHostID,
                            mode: PaneMode(rawValue: cmd["mode"] as? String ?? "claude") ?? .claude,
                            session: cmd["session"] as? String)
        case "new":
            app.newPane(hostID: cmd["host"] as? String,
                        mode: PaneMode(rawValue: cmd["mode"] as? String ?? "claude") ?? .claude,
                        session: cmd["session"] as? String)
        case "close": if let p = pane(index) { app.close(p.id) }
        case "kill": if let p = pane(index) { app.kill(p.id) }
        case "focus": if let index { app.focus(index: index) }
        case "maximize": app.toggleMaximize()
        case "reconnect": if let p = pane(index) { app.reconnect(p.id) }
        case "broadcast": app.setBroadcast(cmd["on"] as? Bool ?? !app.broadcast)
        case "station": app.showStation = cmd["on"] as? Bool ?? !app.showStation
        case "type":
            // Goes through the same path as real keystrokes, so broadcast applies.
            if let p = pane(index), let text = cmd["text"] as? String {
                p.terminal.send(source: p.terminal, data: ArraySlice(Array(text.utf8)))
            }
        case "selectAll": pane(index)?.terminal.selectAll()
        case "relay":
            if let to = cmd["to"] as? Int, app.panes.indices.contains(to) {
                app.relay(to: app.panes[to].id, from: pane(index)?.id)
            }
        case "resize":
            if let w = cmd["w"] as? Double, let h = cmd["h"] as? Double, let win = NSApp.windows.first(where: { $0.isVisible }) {
                var f = win.frame
                f.size = NSSize(width: w, height: h)
                win.setFrame(f, display: true, animate: false)
            }
        case "open": if let path = cmd["path"] as? String { app.switchProject(URL(fileURLWithPath: path, isDirectory: true)) }
        case "closeProject": app.leaveProject()
        case "mode": if let m = (cmd["mode"] as? String).flatMap(AppMode.init(rawValue:)) { app.mode = m }
        case "folderPrompt":
            switch cmd["action"] as? String {
            case "sync": app.promptStartSync()
            case "home": app.promptOpenInHome()
            default: app.cancelFolderPrompt()
            }
        case "state": write(stateJSON(), to: cmd["out"] as? String)
        case "snapshot":
            if let out = cmd["out"] as? String { snapshot(to: out) }
        case "key":
            // Synthetic keyDown into the key window, so shortcut handling can be tested.
            // {"cmd":"key","code":17,"chars":"t","mods":["cmd","shift"]}
            if let code = cmd["code"] as? Int { key(code: UInt16(code), chars: cmd["chars"] as? String ?? "",
                                                   mods: cmd["mods"] as? [String] ?? []) }
        case "click":
            // Synthetic click at window coordinates (origin bottom left), count 2 for a double click.
            if let x = cmd["x"] as? Double, let y = cmd["y"] as? Double { click(at: NSPoint(x: x, y: y), count: cmd["count"] as? Int ?? 1) }
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    private func key(code: UInt16, chars: String, mods: [String]) {
        var flags: NSEvent.ModifierFlags = []
        for m in mods {
            switch m {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        // Arrow keys carry function key characters and flags, or SwiftUI ignores them.
        let arrows: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                     125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
        var chars = chars
        if let fk = arrows[code], let scalar = UnicodeScalar(fk) {
            chars = String(Character(scalar))
            flags.formUnion([.function, .numericPad])
        }
        guard let win = NSApp.keyWindow ?? app.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: win.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func click(at point: NSPoint, count: Int) {
        guard let win = app.window else { return }
        for n in 1...max(1, count) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: win.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: n, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
    }

    private func stateJSON() -> Data {
        let panes: [[String: Any]] = app.panes.enumerated().map { i, p in
            let dims = p.terminal.terminalDimensions
            var state = "connecting"
            switch p.state {
            case .connecting: state = "connecting"
            case .live: state = "live"
            case .exited: state = "exited"
            }
            return ["index": i, "host": p.host.id, "session": p.session, "mode": p.mode.rawValue,
                    "state": state, "focused": p.id == app.focusedID, "cols": dims.cols, "rows": dims.rows,
                    "frame": NSStringFromRect(p.terminal.convert(p.terminal.bounds, to: nil)),
                    "inWindow": p.terminal.window != nil, "bg": "\(p.terminal.nativeBackgroundColor)", "layerBg": "\(String(describing: p.terminal.layer?.backgroundColor))", "screen": p.screenText()]
        }
        var folderPrompt: Any = NSNull()
        if let p = app.folderPrompt {
            var phase = "missing", output = ""
            switch p.phase {
            case .missing: break
            case .syncing: phase = "syncing"
            case .failed(let o): phase = "failed"; output = o
            }
            folderPrompt = ["host": p.host.id, "phase": phase, "output": output]
        }
        let project: Any = app.project.map { p in
            ["name": p.name, "path": p.path, "slug": p.slug, "pcRelativePath": p.pcRelativePath]
        } ?? NSNull()
        let obj: [String: Any] = ["project": project, "mode": app.mode.rawValue, "welcome": app.showsWelcome,
                                  "recents": app.recentProjects.map(\.path), "folderPrompt": folderPrompt,
                                  "projectSync": app.projectSyncActive,
                                  "panes": panes, "broadcast": app.broadcast,
                                  "maximized": app.panes.firstIndex { $0.id == app.maximizedID } ?? -1,
                                  "station": app.showStation, "toast": app.toast ?? "",
                                  "newPaneOpen": app.showNewPane,
                                  "syncInstalled": app.sync.installed,
                                  "sync": app.sync.sessions.map { s in
                                      ["name": s.name ?? "", "status": s.statusWord, "color": s.health.name,
                                       "conflicts": s.conflictRoots] as [String: Any]
                                  }, "active": NSApp.isActive,
                                  "windows": NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) key=\($0.isKeyWindow) fr=\($0.firstResponder.map { "\(type(of: $0))" } ?? "-")" }, "relayPickerOpen": app.showRelayPicker,
                                  "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "",
                                  "firstResponder": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? ""]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private func write(_ data: Data, to path: String?) {
        guard let path else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// cacheDisplay leaves terminal default background cells transparent (on
    /// screen the terminal layer's background shows through), so composite it
    /// over the window color with each terminal's rect filled in the pane color.
    private func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: cached)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        Theme.window.setFill()
        view.bounds.fill()
        Theme.pane.setFill()
        for pane in app.panes where pane.terminal.window === view.window && !pane.terminal.isHiddenOrHasHiddenAncestor {
            pane.terminal.convert(pane.terminal.bounds, to: view).fill()
        }
        cached.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        write(out.representation(using: .png, properties: [:]) ?? Data(), to: path)
    }
}
