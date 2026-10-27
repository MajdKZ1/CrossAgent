#if DEBUG
import AppKit

/// Commands for recording the README GIFs (see scripts/demo/).
///
///     {"cmd":"windowSize","w":1280,"h":800}      key window's content size, then centered
///     {"cmd":"cursor","hidden":true}             hides the mouse pointer (false shows it)
///     {"cmd":"windowID","out":"/tmp/id.txt"}     key window's CGWindowID, for screencapture -l
extension Automation {
    private static var cursorHidden = false

    func handleRecording(_ name: String, _ cmd: [String: Any]) -> Bool {
        let win = app.window ?? NSApp.keyWindow
        switch name {
        case "windowSize":
            guard let win, let w = (cmd["w"] as? NSNumber)?.doubleValue, let h = (cmd["h"] as? NSNumber)?.doubleValue,
                  w > 0, h > 0 else { return true }
            win.setContentSize(NSSize(width: w, height: h))
            win.center()
        case "cursor":
            // NSCursor hide and unhide nest, so only flip when the state really changes.
            let hide = cmd["hidden"] as? Bool ?? true
            guard hide != Self.cursorHidden else { return true }
            Self.cursorHidden = hide
            if hide { NSCursor.hide() } else { NSCursor.unhide() }
        case "windowID":
            guard let path = cmd["out"] as? String else { return true }
            try? Data("\(win?.windowNumber ?? 0)\n".utf8).write(to: URL(fileURLWithPath: path))
        default:
            return false
        }
        return true
    }
}
#endif
