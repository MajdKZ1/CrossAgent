#if DEBUG
import AppKit
import SwiftUI

/// Dev only, for recordings: Puff in a given mood on command, a trick without a
/// click, and a big close-up window.
@MainActor
enum MascotDemo {
    /// Every Puff shows this instead of its graph's mood while set.
    static var mood: MascotMood? {
        didSet { for v in views.allObjects { v.refreshMood() } }
    }

    /// Every live Puff, held weakly.
    static let views = NSHashTable<MascotLayerView>.weakObjects()
    private static var closeUp: NSWindow?

    /// Gallery names, plus a few plain words for them.
    static func mood(named name: String) -> MascotMood? {
        let aliases = ["alarmed": "needsInput", "asking": "needsInput", "celebrating": "done", "happy": "done",
                       "sleepy": "sleeping", "asleep": "sleeping", "busy": "juggling"]
        let key = aliases[name] ?? name
        return MascotGallery.samples.first { $0.name == key }?.mood
    }

    /// Plays on every Puff on screen.
    static func trick(_ name: String?) {
        for v in views.allObjects where v.isShowing { v.playTrick(name) }
    }

    /// A window with Puff big, following `graph` (or idle with none), unless a mood is forced.
    @discardableResult
    static func showCloseUp(graph: AgentGraph?, scale: CGFloat) -> NSWindow {
        closeUp?.close()
        let root = ZStack {
            Palette.window
            if let graph {
                MascotView(graph: graph, scale: scale)
            } else {
                MascotLayer(source: .fixed(.idle), scale: scale)
            }
        }
        let size = MascotLayerView.size(scale: scale)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width + 160, height: size.height + 140),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Puff"
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(Palette.window)
        w.contentView = NSHostingView(rootView: root)
        w.center()
        w.makeKeyAndOrderFront(nil)
        closeUp = w
        return w
    }

    static func hideCloseUp() {
        closeUp?.close()
        closeUp = nil
    }
}
#endif
