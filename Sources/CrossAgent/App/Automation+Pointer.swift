import AppKit

/// Synthetic pointer input for testing the canvas without moving the real cursor.
/// Coordinates are window coordinates, origin bottom left, like `click`.
///
///     {"cmd":"drag","x":200,"y":300,"toX":400,"toY":300,"steps":12,"mods":["option"]}
///     {"cmd":"scroll","x":550,"y":375,"dx":0,"dy":-40,"mods":["cmd"]}
///     {"cmd":"magnify","x":550,"y":375,"amount":0.25}
///     {"cmd":"dblclick","x":100,"y":100}
///     {"cmd":"tap","node":"w1"}
///     {"cmd":"drag","node":"w1","dx":-100,"dy":50}
///     {"cmd":"hittest","node":"w1","out":"/tmp/hit.txt"}
///
/// "node" aims at a canvas node's current center instead of x,y; "dx","dy" move from
/// there (window coordinates, so dy > 0 is up).
///
/// Optional "window": a window title to target; otherwise the window with the
/// orchestrator canvas, else the key window.
extension Automation {
    func handlePointer(_ name: String, _ cmd: [String: Any]) -> Bool {
        PointerAutomation.handle(name, cmd)
    }
}

@MainActor
enum PointerAutomation {
    /// Returns false for commands that are not pointer commands.
    static func handle(_ name: String, _ cmd: [String: Any]) -> Bool {
        guard ["drag", "scroll", "magnify", "dblclick", "tap", "hittest"].contains(name) else { return false }
        guard let win = window(cmd["window"] as? String) else { return true }
        var p = NSPoint(x: number(cmd["x"]), y: number(cmd["y"]))
        var to: NSPoint?
        if let id = cmd["node"] as? String {
            guard let stage = stage(in: win.contentView), let at = stage.windowPoint(of: id) else { return true }
            p = at
            to = NSPoint(x: at.x + number(cmd["dx"]), y: at.y + number(cmd["dy"]))
        }
        let mods = flags(cmd["mods"] as? [String] ?? [])
        switch name {
        case "drag":
            let end = to ?? NSPoint(x: number(cmd["toX"], p.x), y: number(cmd["toY"], p.y))
            // "noUp": true leaves the button down, to test recovering from a lost mouseUp.
            drag(in: win, from: p, to: end, steps: max(1, Int(number(cmd["steps"], 10))), mods: mods,
                 up: cmd["noUp"] as? Bool != true)
        case "scroll":
            scroll(in: win, at: p, dx: number(cmd["dx"]), dy: number(cmd["dy"]), mods: mods)
        case "magnify":
            magnify(in: win, at: p, amount: number(cmd["amount"]))
        case "hittest":
            // Which view a click at the point would reach, innermost first.
            if let out = cmd["out"] as? String, let content = win.contentView {
                var v = content.hitTest(content.convert(p, from: nil))
                var chain: [String] = []
                while let view = v, chain.count < 5 { chain.append("\(type(of: view))"); v = view.superview }
                try? chain.joined(separator: " < ").write(toFile: out, atomically: true, encoding: .utf8)
            }
        case "tap":
            post(.leftMouseDown, in: win, at: p, mods: mods, clicks: 1)
            post(.leftMouseUp, in: win, at: p, mods: mods, clicks: 1)
        case "dblclick":
            for n in 1...2 {
                post(.leftMouseDown, in: win, at: p, mods: mods, clicks: n)
                post(.leftMouseUp, in: win, at: p, mods: mods, clicks: n)
            }
        default:
            break
        }
        return true
    }

    // MARK: - Events

    /// Events go out about 60 per second like a real mouse; SwiftUI gestures only see
    /// the last of a burst posted all at once.
    static func drag(in win: NSWindow, from a: NSPoint, to b: NSPoint, steps: Int, mods: NSEvent.ModifierFlags,
                     up: Bool = true) {
        let interval = 1.0 / 60
        post(.leftMouseDown, in: win, at: a, mods: mods, clicks: 1)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                post(.leftMouseDragged, in: win, at: p, mods: mods, clicks: 1)
            }
        }
        guard up else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(steps + 1)) {
            post(.leftMouseUp, in: win, at: b, mods: mods, clicks: 1)
        }
    }

    /// Pixel scroll built as a CGEvent (NSEvent has no scroll constructor) and handed
    /// straight to the view under the point, so it never goes near the real cursor.
    /// The event has no window, and a windowless event reports its screen position as
    /// its location in window, so it is placed at the window point itself.
    static func scroll(in win: NSWindow, at p: NSPoint, dx: CGFloat, dy: CGFloat, mods: NSEvent.ModifierFlags) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        cg.flags = cgFlags(mods)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: p.x, y: mainHeight - p.y)
        guard let e = NSEvent(cgEvent: cg), let content = win.contentView,
              let view = content.hitTest(content.convert(p, from: nil)) else { return }
        view.scrollWheel(with: e)
    }

    /// Gesture events can't be synthesized, so this calls the canvas zoom directly,
    /// the same path a pinch takes.
    static func magnify(in win: NSWindow, at p: NSPoint, amount: CGFloat) {
        guard let stage = stage(in: win.contentView) else { return }
        stage.zoom(by: 1 + amount, at: stage.convert(p, from: nil))
    }

    private static func post(_ type: NSEvent.EventType, in win: NSWindow, at p: NSPoint,
                             mods: NSEvent.ModifierFlags, clicks: Int) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        NSApp.postEvent(e, atStart: false)
    }

    // MARK: - Helpers

    static func window(_ title: String?) -> NSWindow? {
        let visible = NSApp.windows.filter(\.isVisible)
        if let title { return visible.first { $0.title == title } }
        return visible.first { stage(in: $0.contentView) != nil } ?? NSApp.keyWindow ?? visible.first
    }

    static func stage(in view: NSView?) -> CanvasStage? {
        guard let view else { return nil }
        if let s = view as? CanvasStage { return s }
        for sub in view.subviews { if let s = stage(in: sub) { return s } }
        return nil
    }

    private static func number(_ v: Any?, _ fallback: CGFloat = 0) -> CGFloat {
        (v as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback
    }

    private static func flags(_ mods: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for m in mods {
            switch m {
            case "cmd": f.insert(.command)
            case "shift": f.insert(.shift)
            case "option": f.insert(.option)
            case "ctrl": f.insert(.control)
            default: break
            }
        }
        return f
    }

    private static func cgFlags(_ f: NSEvent.ModifierFlags) -> CGEventFlags {
        var c: CGEventFlags = []
        if f.contains(.command) { c.insert(.maskCommand) }
        if f.contains(.shift) { c.insert(.maskShift) }
        if f.contains(.option) { c.insert(.maskAlternate) }
        if f.contains(.control) { c.insert(.maskControl) }
        return c
    }
}
