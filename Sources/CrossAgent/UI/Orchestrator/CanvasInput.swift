import AppKit
import SwiftUI

/// Invisible backing view for the canvas. Catches scroll wheel events over it (SwiftUI
/// has no scroll wheel gesture) and reports when its window is occluded so the canvas
/// can stop animating. Never takes clicks.
struct CanvasInput: NSViewRepresentable {
    var onScroll: (NSEvent, CGPoint) -> Void
    var onVisible: (Bool) -> Void

    func makeNSView(context: Context) -> CanvasInputView { CanvasInputView() }

    func updateNSView(_ v: CanvasInputView, context: Context) {
        v.onScroll = onScroll
        v.onVisible = onVisible
    }

    static func dismantleNSView(_ v: CanvasInputView, coordinator: ()) {
        v.stop()
    }
}

final class CanvasInputView: NSView {
    var onScroll: ((NSEvent, CGPoint) -> Void)?
    var onVisible: ((Bool) -> Void)?
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    /// Dev only: keep animating under other windows, for measuring.
    private let ignoreOcclusion = ProcessInfo.processInfo.environment["CROSSAGENT_ORCH_IGNORE_OCCLUSION"] == "1"

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, e.window === self.window, !self.isHiddenOrHasHiddenAncestor else { return e }
            let p = self.convert(e.locationInWindow, from: nil)
            guard self.bounds.contains(p) else { return e }
            self.onScroll?(e, p)
            return nil
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportVisibility() }
        }
        reportVisibility()
    }

    private func reportVisibility() {
        guard let window else { return }
        onVisible?(ignoreOcclusion || window.occlusionState.contains(.visible))
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        monitor = nil
        observer = nil
    }
}
