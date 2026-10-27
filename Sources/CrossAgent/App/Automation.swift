import AppKit

/// Dev only remote control so flows can be tested without clicking.
/// Off unless CROSSAGENT_AUTOMATION=1 or `defaults write dev.crossagent automation -bool true`.
/// Send commands with scripts/automation.sh.
///
/// Commands act on the key project window (or the one focused last). Add
/// "project": "<path>" to any command to aim it at that project's window instead.
///
///     {"cmd":"open","path":"/tmp/x"}             opens a window, or brings the open one forward
///     {"cmd":"windows","out":"/tmp/w.json"}      every window: project, title, frame, tabs
///     {"cmd":"closeWindow","project":"/tmp/x"}   like the close button
///     {"cmd":"mergeWindows"}                     Window > Merge All Windows
@MainActor
final class Automation {
    /// CROSSAGENT_AUTOMATION_ID gives an instance its own channel, so parallel test runs don't collide.
    static let notification = Notification.Name("dev.crossagent.automation"
        + (ProcessInfo.processInfo.environment["CROSSAGENT_AUTOMATION_ID"].map { ".\($0)" } ?? ""))
    let windows: ProjectWindows
    /// The window the command being handled acts on.
    private(set) weak var app: AppState!
    private var observer: NSObjectProtocol?

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["CROSSAGENT_AUTOMATION"] == "1"
            || UserDefaults.standard.bool(forKey: "automation")
    }

    init(windows: ProjectWindows) {
        self.windows = windows
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
        switch name {
        case "open":
            if let path = cmd["path"] as? String { windows.open(URL(fileURLWithPath: path, isDirectory: true)) }
            return
        case "windows":
            write(windowsJSON(), to: cmd["out"] as? String)
            return
        case "quit":
            NSApp.terminate(nil)
            return
        default: break
        }
        guard let target = (cmd["project"] as? String).map(windows.state(path:)) ?? windows.current else { return }
        app = target
        let index = cmd["index"] as? Int
        func pane(_ i: Int?) -> PaneSession? {
            guard let i else { return app.focused }
            return app.panes.indices.contains(i) ? app.panes[i] : nil
        }
        if handlePointer(name, cmd) { return }
        if handleTerminal(name, cmd) { return }
        if handleTheme(name, cmd) { return }
        if handleSessions(name, cmd) { return }
        if handleRemote(name, cmd) { return }
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
            // "tab": an agent tab's id types into its terminal instead.
            if let p = (cmd["tab"] as? String).flatMap({ app.agentPanes[$0] }) ?? pane(index), let text = cmd["text"] as? String {
                p.terminal.send(source: p.terminal, data: ArraySlice(Array(text.utf8)))
            }
        case "selectAll": pane(index)?.terminal.selectAll()
        case "relay":
            if let to = cmd["to"] as? Int, app.panes.indices.contains(to) {
                app.relay(to: app.panes[to].id, from: pane(index)?.id)
            }
        case "resize":
            if let w = cmd["w"] as? Double, let h = cmd["h"] as? Double, let win = app.window {
                var f = win.frame
                f.size = NSSize(width: w, height: h)
                win.setFrame(f, display: true, animate: false)
            }
        case "closeProject": app.leaveProject()
        case "closeWindow": app.window?.performClose(nil)
        case "mergeWindows": app.window?.mergeAllWindows(nil)
        case "mode": if let m = (cmd["mode"] as? String).flatMap(AppMode.init(rawValue:)) { app.toggleModeOn(m) }
        case "tab":
            if let id = cmd["id"] as? String { app.select(id) } else if let index { app.select(index: index) }
        case "closeTab":
            if let id = cmd["id"] as? String { app.closeTab(id) } else if let index, app.tabs.indices.contains(index) {
                app.closeTab(app.tabs[index].id)
            } else { app.closeTab() }
        case "moveTab":
            if let from = cmd["from"] as? Int, let to = cmd["to"] as? Int { app.moveTab(from: from, to: to) }
        case "openAgent":
            if let node = cmd["node"] as? String {
                app.openAgent(.node(node))
            } else if let host = cmd["host"] as? String, let session = cmd["session"] as? String {
                app.openAgent(.session(host: host, name: session))
            }
        case "openTab":
            // {"cmd":"openTab","kind":"station"} for panes, station, orchestrator, activity, sessions.
            switch cmd["kind"] as? String {
            case "panes": app.open(.panes)
            case "station": app.open(.station)
            case "orchestrator": app.open(.orchestrator)
            case "activity": app.open(.activity)
            case "sessions": app.open(.sessions)
            default: break
            }
        case "folderPrompt":
            switch cmd["action"] as? String {
            case "sync": app.promptStartSync()
            case "home": app.promptOpenInHome()
            default: app.cancelFolderPrompt()
            }
        case "orchStart": app.launchOrchestrator(hostID: cmd["host"] as? String ?? app.lastHostID)
        case "orchOff": app.turnOffOrchestrator()
        case "expand": if let id = cmd["id"] as? String { app.expandNode(id) }
        case "answer": if let id = cmd["id"] as? String { app.answerNode(id) }
        case "closeDetail": app.closeNodeOverlays()
        case "nodeSend":
            // Same path as the detail card's input box.
            if let id = cmd["id"] as? String, let text = cmd["text"] as? String { app.sendToNode(id, text: text) }
        case "relayNodes":
            // Opens the relay card like a cable drop, then sends it. Without text the
            // source terminal's selection is used.
            if let from = cmd["from"] as? String, let to = cmd["to"] as? String {
                app.openNodeRelay(from: from, to: to)
                if var r = app.orch?.relay {
                    if let text = cmd["text"] as? String { r.text = text }
                    if cmd["send"] as? Bool ?? true { app.sendNodeRelay(r) } else { app.orch?.relay = r }
                }
            }
        case "inject":
            if let list = cmd["events"] as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: list),
               let events = try? JSONDecoder().decode([AgentEvent].self, from: data) {
                app.injectEvents(events)
            }
        case "demo": app.playDemo()
        case "nodePosition":
            // Same as dropping a dragged node: positions change, then a debounced save.
            if let id = cmd["id"] as? String, let x = cmd["x"] as? Double, let y = cmd["y"] as? Double {
                if let o = app.orch, o.demoGraph != nil {
                    o.demoPositions[id] = CGPoint(x: x, y: y)
                } else {
                    app.nodePositions[id] = CGPoint(x: x, y: y)
                    app.scheduleOrchestratorSave()
                }
            }
        case "clearFinished": app.clearFinishedAgents()
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
        var orchestrator: Any = NSNull()
        var graph: [[String: Any]] = []
        if let o = app.orch {
            let pane = app.orchestratorPane
            orchestrator = ["running": pane?.isLive ?? false, "host": pane?.host.id ?? NSNull(),
                            "session": pane?.session ?? NSNull(), "enabled": o.enabled, "busy": o.busy,
                            "following": o.controller.isRunning,
                            "workerPanes": o.workerPanes.mapValues { $0.isLive ? "live" : ($0.isExited ? "exited" : "connecting") },
                            "relay": o.relay.map { ["from": $0.from, "to": $0.to, "text": $0.text] } ?? NSNull(),
                            "answering": o.answering ?? NSNull(),
                            "finished": o.shown.finished, "demo": o.demoGraph != nil,
                            "unverifiedWorkers": Array(o.unverifiedWorkers),
                            "monitorFast": app.monitor?.isActive ?? false] as [String: Any]
            graph = o.shown.nodes.values.sorted { $0.startedAt < $1.startedAt }.map { n in
                var state: [String: Any] = [:]
                switch n.state {
                case .thinking: state = ["kind": "thinking"]
                case .working: state = ["kind": "working"]
                case .needsInput(let q): state = ["kind": "needsInput", "text": q]
                case .waiting(let names): state = ["kind": "waiting", "names": names]
                case .idle: state = ["kind": "idle"]
                case .done: state = ["kind": "done"]
                case .error(let e): state = ["kind": "error", "text": e]
                }
                return ["id": n.id, "name": n.name, "kind": n.kind.rawValue, "host": n.hostId, "state": state,
                        "activity": n.activity, "flow": n.flow.rawValue, "session": n.tmuxSession ?? NSNull()]
            }
        }
        let project: Any = app.project.map { p in
            ["name": p.name, "path": p.path, "slug": p.slug, "pcRelativePath": p.pcRelativePath]
        } ?? NSNull()
        let tabs: [[String: Any]] = app.tabs.map { t in
            var kind: Any = "\(t.mode.rawValue)"
            switch t.kind {
            case .agent(.node(let id)): kind = ["agent": ["node": id]]
            case .agent(.session(let h, let n)): kind = ["agent": ["host": h, "session": n]]
            case .agent(.claude(let h, let sid)): kind = ["agent": ["host": h, "claude": sid]]
            case .dev(let d): kind = ["dev": d.rawValue]
            default: break
            }
            var row: [String: Any] = ["id": t.id, "kind": kind, "title": app.title(of: t)]
            if let p = app.agentTerminal(t) {
                row["terminal"] = p.isLive ? "live" : (p.isExited ? "exited" : "connecting")
            }
            if case .agent(.session(let h, let n)) = t.kind,
               let also = SessionViewersNote.text(SessionDiscovery.shared.sessions, hostId: h, tmux: n) {
                row["alsoOpen"] = also
            }
            return row
        }
        var detail: Any = NSNull()
        if case .agent(let ref)? = app.selectedTab?.kind {
            switch ref {
            case .node(let id): detail = id
            case .session(let h, let n): detail = "\(h)/\(n)"
            case .claude(let h, let sid): detail = "claude:\(h)/\(sid)"
            }
        }
        let obj: [String: Any] = ["project": project, "mode": app.mode.rawValue, "welcome": app.showsWelcome,
                                  "liveViews": liveViewsJSON(), "orchestratorPick": app.orchestratorSessionPick ?? NSNull(),
                                  "tabs": tabs, "selectedTab": app.selectedTabID,
                                  "openProjects": windows.openPaths,
                                  "orchestrator": orchestrator, "graph": graph, "detail": detail,
                                  "detailScreen": app.selectedAgentTerminal?.screenText() ?? NSNull(),
                                  "nodePositions": app.nodePositions.mapValues { [$0.x, $0.y] },
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
                                  "windows": Self.realWindows.count,
                                  "windowList": NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) key=\($0.isKeyWindow) fr=\($0.firstResponder.map { "\(type(of: $0))" } ?? "-")" }, "relayPickerOpen": app.showRelayPicker,
                                  "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "",
                                  "firstResponder": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? ""]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Visible windows that aren't popovers, tooltips or menus: one per open project
    /// (or the welcome window), plus Settings if it's up.
    static var realWindows: [NSWindow] {
        NSApp.windows.filter { w in
            w.isVisible && w.styleMask.contains(.titled) && !String(describing: type(of: w)).contains("Popover")
        }
    }

    /// Every project window, front first, and what the Window menu lists.
    private func windowsJSON() -> Data {
        let list: [[String: Any]] = windows.states.map { s in
            let w = s.window
            return ["project": s.project?.path ?? NSNull(), "title": w?.title ?? "", "key": w?.isKeyWindow ?? false,
                    "current": s === windows.current, "visible": w?.isVisible ?? false,
                    "frame": w.map { NSStringFromRect($0.frame) } ?? "", "frameName": w?.frameAutosaveName ?? "",
                    "tabs": s.tabs.map(\.title), "selectedTab": s.selectedTab?.title ?? "", "mode": s.mode.rawValue,
                    "panes": s.panes.map(\.session), "mergedWith": (w?.tabbedWindows?.count ?? 1) - 1,
                    "tabBar": w?.tabGroup?.isTabBarVisible ?? false,
                    "contentLayout": w.map { NSStringFromRect($0.contentLayoutRect) } ?? ""]
        }
        let menu = NSApp.windowsMenu?.items.filter { $0.target is NSWindow }.map(\.title) ?? []
        let obj: [String: Any] = ["windows": list, "openProjects": windows.openPaths, "windowsMenu": menu,
                                  "realWindows": Self.realWindows.count, "monitorFast": windows.monitor.isActive]
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
        guard let view = app.window?.contentView,
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
        // An agent tab's terminal sits over the hidden grid, so draw it again on its own background.
        if let t = app.selectedAgentTerminal?.terminal, t.window === view.window, let rep = t.bitmapImageRepForCachingDisplay(in: t.bounds) {
            t.cacheDisplay(in: t.bounds, to: rep)
            var rect = t.convert(t.bounds, to: view)
            if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            Theme.pane.setFill()
            rect.fill()
            rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        write(out.representation(using: .png, properties: [:]) ?? Data(), to: path)
    }
}
