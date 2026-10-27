import AppKit
import SwiftTerm

/// Terminal colours and font, from the current theme in `ThemeTokens`.
enum Theme {
    static var window: NSColor { ThemeTokens.shared.resolved.window }
    static var pane: NSColor { ThemeTokens.shared.resolved.background }
    static var foreground: NSColor { ThemeTokens.shared.resolved.foreground }

    static let font: NSFont = {
        // JetBrains Mono if installed, else SF Mono (the system monospaced font; "SFMono-Regular"
        // isn't a name NSFont resolves), never Menlo unless both fail.
        for name in ["JetBrainsMono-Regular", "JetBrains Mono"] {
            if let f = NSFont(name: name, size: 13) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }()

    /// Every terminal `apply` has seen, held weakly so a theme switch can reach them all.
    @MainActor private static let live = NSHashTable<TerminalView>.weakObjects()

    @MainActor
    static func apply(to view: TerminalView) {
        // Make sure the saved theme is loaded before the first terminal is coloured.
        _ = ThemeStore.shared
        let t = ThemeTokens.shared.resolved
        // SwiftTerm paints the default background on its layer, so make sure
        // the layer exists before the color is set or it is silently dropped.
        view.wantsLayer = true
        if view.font != font { view.font = font }
        view.nativeBackgroundColor = t.background
        view.nativeForegroundColor = t.foreground
        // After fg and bg, so the 256 colour palette SwiftTerm derives uses the new ones.
        view.installColors(t.ansi.map(Self.terminalColor))
        view.caretColor = t.cursor
        view.selectedTextBackgroundColor = t.selection
        view.selectedTextForegroundColor = t.selectionForeground
        view.optionAsMetaKey = true
        view.layer?.backgroundColor = t.background.cgColor
        // installColors already marks the whole buffer for a full repaint. Ask for the
        // frame too: drawn on the next tick while visible, or when the window shows
        // again if SwiftTerm paused rendering because it is covered.
        TerminalAppearance.apply(to: view)
        view.requestRedraw()
        view.needsDisplay = true
        register(view)
    }

    /// Terminals currently themed, for automation checks.
    @MainActor static var liveTerminals: [TerminalView] { live.allObjects }

    @MainActor
    static func register(_ view: TerminalView) {
        live.add(view)
    }

    /// Recolours every live terminal, and every window whose background is `oldWindow`.
    @MainActor
    static func applyToAll(replacingWindow oldWindow: NSColor? = nil) {
        for view in live.allObjects { apply(to: view) }
        guard let oldWindow else { return }
        for w in NSApp?.windows ?? [] where w.backgroundColor == oldWindow {
            w.backgroundColor = window
        }
    }

    /// SwiftTerm colours are 16 bit per channel.
    static func terminalColor(_ c: NSColor) -> SwiftTerm.Color {
        let s = c.usingColorSpace(.sRGB) ?? c
        func ch(_ v: CGFloat) -> UInt16 { UInt16((min(max(v, 0), 1) * 65535).rounded()) }
        return SwiftTerm.Color(red: ch(s.redComponent), green: ch(s.greenComponent), blue: ch(s.blueComponent))
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 8 {
            self.init(srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                      blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
        } else {
            self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                      blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
    }
}
