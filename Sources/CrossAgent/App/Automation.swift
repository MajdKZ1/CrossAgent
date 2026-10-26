import AppKit

/// Dev only remote control so flows can be tested without clicking.
/// Off unless CROSSAGENT_AUTOMATION=1 or `defaults write dev.crossagent automation -bool true`.
/// Send commands with scripts/automation.sh.
@MainActor
final class Automation {
    static let notification = Notification.Name("dev.crossagent.automation")
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
        case "state": write(stateJSON(), to: cmd["out"] as? String)
        case "snapshot":
            if let out = cmd["out"] as? String { snapshot(to: out) }
        case "quit": NSApp.terminate(nil)
        default: break
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
                    "inWindow": p.terminal.window != nil, "screen": p.screenText()]
        }
        let obj: [String: Any] = ["panes": panes, "broadcast": app.broadcast,
                                  "maximized": app.panes.firstIndex { $0.id == app.maximizedID } ?? -1,
                                  "station": app.showStation, "toast": app.toast ?? ""]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private func write(_ data: Data, to path: String?) {
        guard let path else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        write(rep.representation(using: .png, properties: [:]) ?? Data(), to: path)
    }
}
