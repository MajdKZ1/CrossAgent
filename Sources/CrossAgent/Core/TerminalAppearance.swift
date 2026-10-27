import AppKit
import SwiftTerm

/// Font metrics and system colour hooks for terminals. `Theme.apply` calls `apply(to:)`
/// after it set the font, so every font a theme picks gets native line heights.
enum TerminalAppearance {
    static func apply(to view: TerminalView) {
        let spacing = lineSpacing(for: view.font)
        // lineSpacing resets the font and resizes, so only touch it when it changes.
        if abs(view.lineSpacing - spacing) > 0.0001 { view.lineSpacing = spacing }
    }

    /// The row height Terminal.app (NSLayoutManager) uses: ascent, descent and leading
    /// each rounded to whole points. Menlo 13 gets 15 pt, JetBrains Mono 13 gets 17 pt,
    /// same as Ghostty.
    static func nativeLineHeight(for font: NSFont) -> CGFloat {
        let ct = font as CTFont
        return max(1, CTFontGetAscent(ct).rounded() + CTFontGetDescent(ct).rounded() + CTFontGetLeading(ct).rounded())
    }

    /// SwiftTerm makes a row `ceil(ascent + descent + leading)` tall, a point more than
    /// native terminals for fonts like Menlo (16 instead of 15). Its `lineSpacing`
    /// multiplier is applied before that ceil, so aim just under the native height.
    static func lineSpacing(for font: NSFont) -> CGFloat {
        let ct = font as CTFont
        let natural = CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
        let target = nativeLineHeight(for: font)
        guard natural > 0, ceil(natural) != target else { return 1 }
        return (target - 0.001) / natural
    }

    /// Row height SwiftTerm ends up with for a font and spacing, at a backing scale.
    static func rowHeight(for font: NSFont, lineSpacing: CGFloat, scale: CGFloat = 2) -> CGFloat {
        let ct = font as CTFont
        let h = ceil((CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * lineSpacing)
        return ceil(h * scale) / scale
    }

    /// Selection colour that follows the system accent, for themes that leave it to the
    /// system. Blended over the terminal background so text on it stays readable.
    static func systemSelection(over background: NSColor) -> NSColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let bg = background.usingColorSpace(.sRGB) ?? .black
        return bg.blended(withFraction: 0.45, of: accent) ?? accent
    }
}
