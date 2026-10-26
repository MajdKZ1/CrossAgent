import AppKit
import SwiftTerm

enum Theme {
    static let window = NSColor(hex: "#0b0c0f")
    static let pane = NSColor(hex: "#0f1115")
    static let foreground = NSColor(hex: "#d7dae0")

    static let font: NSFont = {
        for name in ["JetBrainsMono-Regular", "JetBrains Mono", "SFMono-Regular", "Menlo-Regular"] {
            if let f = NSFont(name: name, size: 13) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }()

    static func apply(to view: TerminalView) {
        // SwiftTerm paints the default background on its layer, so make sure
        // the layer exists before the color is set or it is silently dropped.
        view.wantsLayer = true
        view.font = font
        view.nativeBackgroundColor = pane
        view.nativeForegroundColor = foreground
        view.caretColor = NSColor(hex: "#9aa4b2")
        view.optionAsMetaKey = true
        view.layer?.backgroundColor = pane.cgColor
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
