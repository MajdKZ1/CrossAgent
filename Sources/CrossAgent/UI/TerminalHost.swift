import AppKit
import SwiftUI

/// Hosts a pane's long lived terminal view. The view is owned by PaneSession,
/// so SwiftUI relayout or maximize never recreates the terminal.
struct TerminalHost: NSViewRepresentable {
    let terminal: PaneTerminalView
    /// Hidden panes (behind a maximized one) keep their size, so tmux is not resized for nothing.
    var hidden = false

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(to: container)
        container.isHidden = hidden
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if terminal.superview !== container { attach(to: container) }
        if container.isHidden != hidden { container.isHidden = hidden }
    }

    private func attach(to container: NSView) {
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Hands the hosting NSWindow to `onWindow` once the view is on screen.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

/// Empty top bar area: drag moves the window, double click zooms it like a title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}
