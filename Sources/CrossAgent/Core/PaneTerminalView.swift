import AppKit
import SwiftTerm

/// Terminal shortcuts that work while a pane has focus, like in Terminal.app.
enum TerminalKeyAction: Equatable {
    case copy, paste, selectAll, clear, find, findOlder, findNewer

    /// Pure mapping from a key press, so it can be tested without events.
    static func from(chars: String, flags: NSEvent.ModifierFlags) -> TerminalKeyAction? {
        let mods = flags.intersection([.command, .shift, .option, .control])
        switch (chars.lowercased(), mods) {
        case ("c", [.command]): return .copy
        case ("v", [.command]): return .paste
        case ("a", [.command]): return .selectAll
        case ("k", [.command]): return .clear
        case ("f", [.command]): return .find
        case ("g", [.command]): return .findOlder
        case ("g", [.command, .shift]): return .findNewer
        default: return nil
        }
    }
}

/// tmux in copy mode draws its scroll position, like `[12/340]`, at the top right of the pane.
enum TmuxCopyMode {
    static func showsPosition(topRow: String) -> Bool {
        topRow.range(of: #"\[\d+/\d+\]\S*\s*$"#, options: .regularExpression) != nil
    }
}

/// The terminal behind every pane: input hold, broadcast interception, find, clear,
/// a context menu, and wheel scrolling through tmux history.
final class PaneTerminalView: LocalProcessTerminalView {
    /// When set, user keystrokes go here instead of straight to the process.
    var inputInterceptor: ((ArraySlice<UInt8>) -> Void)?
    /// Cmd+K and the Clear menu item. The owner knows the host and the tmux session.
    var onClear: (() -> Void)?

    /// Keys typed before the other side is ready, sent in order once it is. tmux attaching
    /// over ssh can eat input that arrives while it sets up the terminal.
    private var held: [UInt8]?
    /// The wheel moved tmux into copy mode. The next keystroke leaves it first.
    private var tmuxScrolled = false
    private var findBar: FindBar?
    private var showsLinkCursor = false

    /// Tmux scrolls 5 lines per wheel step in copy mode, so 1/5 keeps trackpad
    /// scrolling roughly 1:1 with the fingers.
    static let tmuxWheelSensitivity: CGFloat = 0.2

    /// Call once after creation.
    func configure() {
        // Clicks and drags always select locally. The app inside (tmux with mouse on)
        // only gets the wheel, see `handleWheel`.
        allowMouseReporting = false
        Self.installMonitor()
    }

    // MARK: Input

    func holdInput() { held = held ?? [] }

    func releaseInput() {
        guard let bytes = held else { return }
        held = nil
        if !bytes.isEmpty, process?.running == true { process.send(data: ArraySlice(bytes)) }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let inputInterceptor {
            inputInterceptor(data)
        } else if held != nil {
            held?.append(contentsOf: data)
        } else {
            super.send(source: source, data: data)
        }
    }

    /// Writes bytes straight to the process, skipping the interceptor.
    func write(_ data: ArraySlice<UInt8>) {
        guard process?.running == true else { return }
        process.send(data: data)
    }

    var hasSelection: Bool { getSelection().map { !$0.isEmpty } ?? false }

    // MARK: Shortcuts

    /// Called from the hosting container's performKeyEquivalent, since SwiftTerm's own
    /// override is not open. Only acts while this terminal or its find bar has focus.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window,
              let action = TerminalKeyAction.from(chars: event.charactersIgnoringModifiers ?? "",
                                                  flags: event.modifierFlags) else { return false }
        let responder = window.firstResponder
        if let bar = findBar, !bar.isHidden, let view = responder as? NSView, view.isDescendant(of: bar) {
            // Typing in the find field: editing keys belong to the field.
            switch action {
            case .find: bar.focus()
            case .findOlder: findStep(older: true)
            case .findNewer: findStep(older: false)
            case .copy: NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case .paste: NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case .selectAll: NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            case .clear: clearAction(nil)
            }
            return true
        }
        guard responder === self else { return false }
        perform(action)
        return true
    }

    func perform(_ action: TerminalKeyAction) {
        switch action {
        case .copy: if hasSelection { copy(self) }
        case .paste:
            leaveTmuxScrollback()
            paste(self)
        case .selectAll: selectAll()
        case .clear: onClear?()
        case .find: showFind()
        case .findOlder: findStep(older: true)
        case .findNewer: findStep(older: false)
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                 enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Copy", #selector(copyAction(_:)), "c", enabled: hasSelection)
        add("Paste", #selector(pasteAction(_:)), "v",
            enabled: NSPasteboard.general.string(forType: .string)?.isEmpty == false)
        add("Select All", #selector(selectAllAction(_:)), "a")
        menu.addItem(.separator())
        add("Find…", #selector(findAction(_:)), "f")
        add("Clear", #selector(clearAction(_:)), "k")
        return menu
    }

    @objc private func copyAction(_ sender: Any?) { perform(.copy) }
    @objc private func pasteAction(_ sender: Any?) { perform(.paste) }
    @objc private func selectAllAction(_ sender: Any?) { perform(.selectAll) }
    @objc private func findAction(_ sender: Any?) { perform(.find) }
    @objc private func clearAction(_ sender: Any?) { perform(.clear) }

    // MARK: Find

    var isFindVisible: Bool { findBar.map { !$0.isHidden } ?? false }

    func showFind() {
        let bar = findBar ?? makeFindBar()
        if bar.isHidden {
            bar.isHidden = false
            if let text = getSelection(), !text.isEmpty, !text.contains("\n") { bar.text = text }
            if !bar.text.isEmpty { search(bar.text) }
        }
        bar.focus()
    }

    var findText: String { findBar?.text ?? "" }
    var findCountText: String { findBar?.countText ?? "" }

    /// Same as typing into the field.
    func setFindText(_ text: String) {
        findBar?.text = text
        search(text)
    }

    func hideFind() {
        guard let bar = findBar, !bar.isHidden else { return }
        bar.isHidden = true
        window?.makeFirstResponder(self)
    }

    /// Searches from the bottom up, so the newest match comes first. Returns the match count.
    @discardableResult
    func search(_ term: String) -> Int {
        clearSearch()
        guard !term.isEmpty else {
            findBar?.setCount(nil)
            return 0
        }
        findPrevious(term)
        return updateCount(term)
    }

    /// Older goes up (toward history), newer goes down, like iTerm and Ghostty.
    func findStep(older: Bool) {
        guard let term = findBar?.text, !term.isEmpty else { return }
        if older { findPrevious(term) } else { findNext(term) }
        updateCount(term)
    }

    @discardableResult
    private func updateCount(_ term: String) -> Int {
        let summary = searchMatchSummary(term)
        findBar?.setCount(summary.total == 0 ? (0, 0) : summary)
        return summary.total
    }

    private func makeFindBar() -> FindBar {
        let bar = FindBar()
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onChange = { [weak self] in self?.search($0) }
        bar.onStep = { [weak self] in self?.findStep(older: $0) }
        bar.onClose = { [weak self] in self?.hideFind() }
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
        findBar = bar
        return bar
    }

    // MARK: Scrolling through tmux

    /// Panes run tmux with `mouse on`, which keeps the history. tmux then asks for mouse
    /// reports, so the wheel is sent to it as wheel events (it scrolls in copy mode) while
    /// clicks stay local for native selection. Without mouse mode SwiftTerm handles it.
    fileprivate func handleWheel(_ event: NSEvent) -> Bool {
        guard terminalInputStateSnapshot()?.mouseMode ?? .off != .off else { return false }
        let sensitivity = scrollSensitivity
        allowMouseReporting = true
        scrollSensitivity = Self.tmuxWheelSensitivity
        scrollWheel(with: event)
        scrollSensitivity = sensitivity
        allowMouseReporting = false
        if event.scrollingDeltaY > 0 { tmuxScrolled = true }
        return true
    }

    /// Typing while scrolled back in tmux first leaves copy mode, so the key reaches the
    /// app and the view jumps to the bottom, as in a native terminal.
    func leaveTmuxScrollback() {
        guard tmuxScrolled else { return }
        tmuxScrolled = false
        let top = terminalContentSnapshot(region: .viewport)?.rows.first?.text ?? ""
        if TmuxCopyMode.showsPosition(topRow: top) { write(ArraySlice(Array("q".utf8))) }
    }

    // MARK: Link cursor

    /// Cmd over a link shows the pointing hand. SwiftTerm underlines it and opens it on click.
    fileprivate func updateLinkCursor(at locationInWindow: NSPoint, command: Bool) {
        let onLink = command && link(at: convert(locationInWindow, from: nil)) != nil
        if onLink {
            NSCursor.pointingHand.set()
        } else if showsLinkCursor {
            NSCursor.iBeam.set()
        }
        showsLinkCursor = onLink
    }

    /// The URL under a point, found the way SwiftTerm finds implicit links.
    func link(at point: NSPoint) -> String? {
        let cell = caretFrame.size
        guard cell.width > 0, cell.height > 0, bounds.contains(point),
              let rows = terminalContentSnapshot(region: .viewport)?.rows else { return nil }
        let row = Int((bounds.height - point.y) / cell.height)
        let col = Int(point.x / cell.width)
        guard rows.indices.contains(row) else { return nil }
        let line = rows[row].cells.map { $0.text.isEmpty ? " " : $0.text }.joined()
        return Self.url(in: line, at: col)
    }

    static func url(in line: String, at col: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(https?|file|ssh|ftp)://[^\s"'<>`]+"#) else { return nil }
        let ns = line as NSString
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        where m.range.location <= col && col < m.range.location + m.range.length {
            return ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}"))
        }
        return nil
    }

    // MARK: One event monitor for all panes

    private static var monitor: Any?

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .mouseMoved, .flagsChanged]) { event in
            let swallow = MainActor.assumeIsolated { route(event) == nil }
            return swallow ? nil : event
        }
    }

    private static func route(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            if let window = event.window, routeWheel(event, in: window, at: event.locationInWindow) { return nil }
        case .keyDown:
            guard let responder = event.window?.firstResponder else { break }
            if !event.modifierFlags.contains(.command) {
                (responder as? PaneTerminalView)?.leaveTmuxScrollback()
                break
            }
            // Same shortcuts as the container's performKeyEquivalent. AppKit only offers key
            // equivalents to the key window, so this also covers events that skip that pass.
            var view = responder as? NSView
            while let v = view {
                if let t = v as? PaneTerminalView { return t.handleKeyEquivalent(event) ? nil : event }
                view = v.superview
            }
        case .mouseMoved, .flagsChanged:
            // Key events carry no pointer location, so ask the window.
            guard let window = event.window else { break }
            let point = event.type == .mouseMoved ? event.locationInWindow : window.mouseLocationOutsideOfEventStream
            terminal(in: window, at: point)?.updateLinkCursor(at: point, command: event.modifierFlags.contains(.command))
        default: break
        }
        return event
    }

    /// Wheel handling for the pane under `point`. Also used by automation, whose
    /// synthetic scroll events have no window.
    static func routeWheel(_ event: NSEvent, in window: NSWindow, at point: NSPoint) -> Bool {
        terminal(in: window, at: point)?.handleWheel(event) ?? false
    }

    var isTmuxScrolled: Bool { tmuxScrolled }

    /// The pane terminal really under the pointer, so overlays (canvas, cards) keep their events.
    private static func terminal(in window: NSWindow, at point: NSPoint) -> PaneTerminalView? {
        guard let content = window.contentView, let frame = content.superview else { return nil }
        var view = content.hitTest(frame.convert(point, from: nil))
        while let v = view {
            if let t = v as? PaneTerminalView { return t }
            view = v.superview
        }
        return nil
    }
}
