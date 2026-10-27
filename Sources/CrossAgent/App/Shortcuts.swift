import AppKit

/// App wide shortcuts. SwiftTerm eats keyDown while a terminal is focused, so menu
/// key equivalents are not enough. A local monitor sees every key before any view,
/// handles ours and returns nil so nothing else (menus included) fires twice.
@MainActor
final class Shortcuts {
    private let app: AppState
    private var monitor: Any?
    /// The last key event handled here. SwiftUI still fires a menu item's keyboardShortcut
    /// even after the monitor swallowed the event, so menu actions check this to skip it.
    private static var handled: (timestamp: TimeInterval, keyCode: UInt16)?

    /// True when the current event is a key press this monitor already acted on.
    static var currentEventWasHandled: Bool {
        guard let e = NSApp.currentEvent, e.type == .keyDown, let h = handled else { return false }
        return e.timestamp == h.timestamp && e.keyCode == h.keyCode
    }

    // Physical key codes (ANSI layout positions), so Shift and keyboard layouts do not matter.
    private enum Key {
        static let t: UInt16 = 17, o: UInt16 = 31, w: UInt16 = 13, b: UInt16 = 11, r: UInt16 = 15, v: UInt16 = 9
        static let leftBracket: UInt16 = 33, rightBracket: UInt16 = 30
        static let returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53
        static let up: UInt16 = 126, down: UInt16 = 125
        static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    init(app: AppState) {
        self.app = app
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallowed = MainActor.assumeIsolated {
                guard self?.handle(event) == nil else { return false }
                Self.handled = (event.timestamp, event.keyCode)
                return true
            }
            return swallowed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Popovers (new pane) and other windows keep their own keys.
        guard let main = app.window, event.window === main else { return event }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.keyCode

        if app.showRelayPicker { return handleRelayPicker(key: key, flags: flags) }
        if app.folderPrompt != nil, !flags.contains(.command) { return handleFolderPrompt(key: key) }

        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return event }
        let shift = flags.contains(.shift)

        switch (key, shift) {
        case (Key.t, false): app.openNewPanePopover()
        case (Key.o, false): app.presentOpenPanel()
        case (Key.o, true): if app.project != nil { app.toggleMode(.orchestrator) }
        case (Key.w, false): app.close()
        case (Key.leftBracket, true): app.moveFocus(-1)
        case (Key.rightBracket, true): app.moveFocus(1)
        case (Key.returnKey, false), (Key.enter, false): app.toggleMaximize()
        case (Key.b, true): app.toggleBroadcast()
        case (Key.r, true): app.openRelayPicker()
        case (Key.v, true): app.toggleMode(.station)
        default:
            guard !shift, let n = Key.digits.firstIndex(of: key) else { return event }
            app.focus(index: n)
        }
        return nil
    }

    /// The missing folder card: Enter starts sync, Esc cancels, other plain keys go nowhere.
    private func handleFolderPrompt(key: UInt16) -> NSEvent? {
        switch key {
        case Key.escape: app.cancelFolderPrompt()
        case Key.returnKey, Key.enter: app.promptStartSync()
        default: break
        }
        return nil
    }

    /// While the relay picker is up it owns the keyboard: arrows, 1-9, Enter, Esc.
    private func handleRelayPicker(key: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent? {
        let count = app.relayTargets.count
        switch key {
        case Key.escape: app.closeRelayPicker()
        case Key.up: app.relayPickIndex = max(0, app.relayPickIndex - 1)
        case Key.down: app.relayPickIndex = min(count - 1, app.relayPickIndex + 1)
        case Key.returnKey, Key.enter: app.pickRelay(app.relayPickIndex)
        default:
            if flags.isEmpty, let n = Key.digits.firstIndex(of: key) {
                app.pickRelay(n)
            } else if flags.contains(.command) && flags.contains(.shift) && key == Key.r {
                app.closeRelayPicker()
            }
        }
        return nil
    }
}
