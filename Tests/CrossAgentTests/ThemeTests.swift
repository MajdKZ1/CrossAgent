@testable import CrossAgent
import AppKit
import SwiftTerm
import XCTest

@MainActor
final class ThemeTests: XCTestCase {
    static let themesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CrossAgent/Resources/Themes")

    func builtIn(_ name: String) throws -> AppTheme {
        try ThemeStore.decode(Data(contentsOf: Self.themesDir.appendingPathComponent("\(name).json")), base: nil)
    }

    func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ca-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Format

    func testJSONRoundTrip() throws {
        for name in ["default", "mono"] {
            let theme = try builtIn(name)
            let again = try ThemeStore.decode(JSONEncoder().encode(theme), base: nil)
            XCTAssertEqual(theme, again)
        }
    }

    func testFallbackMatchesDefaultJSON() throws {
        XCTAssertEqual(try builtIn("default"), AppTheme.fallback)
    }

    /// The colours the app used before themes existed.
    func testDefaultEqualsTodaysColours() throws {
        let t = ResolvedTheme(try builtIn("default"))
        func same(_ c: NSColor, _ hex: String, alpha: CGFloat = 1, file: StaticString = #filePath, line: UInt = #line) {
            let a = c.usingColorSpace(.sRGB)!, b = NSColor(hex: hex).usingColorSpace(.sRGB)!
            XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.001, file: file, line: line)
            // Hex alpha is 8 bit, so 0.07 lands within half a step.
            XCTAssertEqual(a.alphaComponent, alpha, accuracy: 0.5 / 255 + 0.0001, file: file, line: line)
        }
        same(t.window, "#0b0c0f"); same(t.surface, "#0f1115"); same(t.background, "#0f1115")
        same(t.text, "#d7dae0"); same(t.foreground, "#d7dae0")
        same(t.muted, "#8a909c"); same(t.faint, "#5b616c")
        same(t.warning, "#f5b041"); same(t.broadcast, "#ff9f6e"); same(t.synced, "#8fd694")
        same(t.accent, "#6ea8fe"); same(t.danger, "#f07178"); same(t.success, "#5fd39a")
        same(t.cursor, "#9aa4b2")
        same(t.border, "#ffffff", alpha: 0.07); same(t.hairline, "#ffffff", alpha: 0.05)
        same(t.chip, "#ffffff", alpha: 0.04); same(t.chipHover, "#ffffff", alpha: 0.08)
        same(t.mascotBody, "#b3dcff"); same(t.mascotEyes, "#0b1218")
        XCTAssertTrue(t.hosts.isEmpty)
        // SwiftTerm's own defaults: Terminal.app ANSI colours and its teal selection with black text.
        let swiftTerm = SwiftTerm.Color.terminalAppColors
        XCTAssertEqual(t.ansi.map(Theme.terminalColor), swiftTerm)
        same(t.selection, "#00a6b2"); same(t.selectionForeground, "#000000")
    }

    // MARK: User themes

    func testUserThemeLoadsAndMergesOverDefault() throws {
        let dir = try tempFolder()
        try ##"{"name": "Sunset", "ui": {"accent": "#ff8800"}, "hosts": {"pc": "#123456"}}"##
            .write(to: dir.appendingPathComponent("sunset.json"), atomically: true, encoding: .utf8)
        try ##"{"ui": {"text": "#eeeeee"}}"##.write(to: dir.appendingPathComponent("nameless.json"), atomically: true, encoding: .utf8)
        let loaded = ThemeStore.loadUserThemes(in: dir, base: try builtIn("default"))
        XCTAssertEqual(loaded.problems, [])
        XCTAssertEqual(loaded.themes.map(\.name), ["nameless", "Sunset"])
        let sunset = loaded.themes[1]
        XCTAssertEqual(sunset.ui.accent, "#ff8800")
        XCTAssertEqual(sunset.ui.text, "#d7dae0")
        XCTAssertEqual(sunset.terminal.ansi.count, 16)
        XCTAssertEqual(sunset.hosts, ["pc": "#123456"])
    }

    func testBadUserFilesAreSkippedWithAReason() throws {
        let dir = try tempFolder()
        let files = [
            "broken.json": "{ not json",
            "short.json": ##"{"name": "Short", "terminal": {"ansi": ["#000000"]}}"##,
            "colour.json": ##"{"name": "Colour", "ui": {"text": "white"}}"##,
            "array.json": "[1, 2]",
            "good.json": ##"{"name": "Good"}"##,
            "notes.txt": "ignored",
        ]
        for (name, body) in files { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let loaded = ThemeStore.loadUserThemes(in: dir, base: try builtIn("default"))
        XCTAssertEqual(loaded.themes.map(\.name), ["Good"])
        XCTAssertEqual(loaded.problems.count, 4)
        XCTAssertTrue(loaded.problems.contains { $0.hasPrefix("Theme broken.json:") && $0.contains("not valid JSON") })
        XCTAssertTrue(loaded.problems.contains { $0.hasPrefix("Theme short.json:") && $0.contains("16 colours") })
        XCTAssertTrue(loaded.problems.contains { $0.hasPrefix("Theme colour.json:") && $0.contains("text") })
        XCTAssertTrue(loaded.problems.contains { $0.hasPrefix("Theme array.json:") })
    }

    func testStoreListsUserThemesAndReplacesBuiltInByName() throws {
        let dir = try tempFolder()
        try ##"{"name": "Mono", "ui": {"accent": "#abcdef"}}"##.write(to: dir.appendingPathComponent("m.json"), atomically: true, encoding: .utf8)
        try "nope".write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        let store = ThemeStore(builtIns: [try builtIn("default"), try builtIn("mono")], userFolder: dir, watch: false)
        XCTAssertEqual(store.all.map(\.name), ["Default", "Mono"])
        XCTAssertEqual(store.all[1].ui.accent, "#abcdef")
        XCTAssertEqual(store.problems.count, 1)
    }

    // MARK: Mono contrast

    static func luminance(_ hex: String) -> Double {
        let c = NSColor(hex: hex).usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    static func contrast(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testMonoContrast() throws {
        let mono = try builtIn("mono")
        XCTAssertEqual(mono.terminal.background, "#101010")
        XCTAssertEqual(mono.terminal.foreground, "#c8c8c8")
        // Check on the lightest surface text sits on, and on the terminal background.
        for bg in [mono.terminal.background, mono.ui.surface, mono.ui.raised] {
            XCTAssertGreaterThanOrEqual(Self.contrast(mono.ui.text, bg), 7, "text on \(bg)")
            XCTAssertGreaterThanOrEqual(Self.contrast(mono.terminal.foreground, bg), 7, "foreground on \(bg)")
            XCTAssertGreaterThanOrEqual(Self.contrast(mono.ui.muted, bg), 4.5, "muted on \(bg)")
        }
        let bg = mono.terminal.background
        for (i, hex) in mono.terminal.ansi.enumerated() {
            if i == 0 { continue }
            XCTAssertGreaterThanOrEqual(Self.contrast(hex, bg), i < 8 ? 3 : 4.5, "ansi \(i) \(hex)")
        }
        XCTAssertGreaterThanOrEqual(Self.contrast(mono.terminal.selectionForeground!, mono.terminal.selection), 7)
        // Bright is a step lighter than normal.
        for i in 0..<8 {
            XCTAssertGreaterThan(Self.luminance(mono.terminal.ansi[i + 8]), Self.luminance(mono.terminal.ansi[i]), "bright \(i)")
        }
    }
}
