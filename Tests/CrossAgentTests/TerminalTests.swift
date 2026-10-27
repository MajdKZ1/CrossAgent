import AppKit
import XCTest
@testable import CrossAgent

final class TerminalTests: XCTestCase {
    func testKeyActions() {
        XCTAssertEqual(TerminalKeyAction.from(chars: "c", flags: .command), .copy)
        XCTAssertEqual(TerminalKeyAction.from(chars: "v", flags: .command), .paste)
        XCTAssertEqual(TerminalKeyAction.from(chars: "a", flags: .command), .selectAll)
        XCTAssertEqual(TerminalKeyAction.from(chars: "k", flags: .command), .clear)
        XCTAssertEqual(TerminalKeyAction.from(chars: "f", flags: .command), .find)
        XCTAssertEqual(TerminalKeyAction.from(chars: "g", flags: .command), .findOlder)
        XCTAssertEqual(TerminalKeyAction.from(chars: "G", flags: [.command, .shift]), .findNewer)
        // Not ours: plain keys, Ctrl+C, and app shortcuts like Cmd+Shift+B.
        XCTAssertNil(TerminalKeyAction.from(chars: "c", flags: []))
        XCTAssertNil(TerminalKeyAction.from(chars: "c", flags: .control))
        XCTAssertNil(TerminalKeyAction.from(chars: "b", flags: [.command, .shift]))
        XCTAssertNil(TerminalKeyAction.from(chars: "k", flags: [.command, .option]))
        // Device independent flags (caps lock, numeric pad) don't matter.
        XCTAssertEqual(TerminalKeyAction.from(chars: "c", flags: [.command, .capsLock]), .copy)
    }

    func testTmuxCopyModeIndicator() {
        XCTAssertTrue(TmuxCopyMode.showsPosition(topRow: "  some output                    [12/340]"))
        XCTAssertTrue(TmuxCopyMode.showsPosition(topRow: "[0/5]"))
        XCTAssertFalse(TmuxCopyMode.showsPosition(topRow: "╭─ Claude Code ─────╮"))
        XCTAssertFalse(TmuxCopyMode.showsPosition(topRow: "array[1/2] is half way through the line"))
    }

    func testURLUnderColumn() {
        let line = "see https://example.com/a?b=1. and more"
        XCTAssertEqual(PaneTerminalView.url(in: line, at: 10), "https://example.com/a?b=1")
        XCTAssertNil(PaneTerminalView.url(in: line, at: 1))
        XCTAssertNil(PaneTerminalView.url(in: line, at: 35))
    }

    func testNativeLineHeight() throws {
        let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13))
        // Terminal.app and Ghostty: 15 pt. SwiftTerm alone: ceil(15.13) = 16.
        XCTAssertEqual(TerminalAppearance.nativeLineHeight(for: menlo), 15)
        XCTAssertEqual(TerminalAppearance.rowHeight(for: menlo, lineSpacing: 1), 16)
        let spacing = TerminalAppearance.lineSpacing(for: menlo)
        XCTAssertLessThan(spacing, 1)
        XCTAssertEqual(TerminalAppearance.rowHeight(for: menlo, lineSpacing: spacing), 15)

        // SF Mono already lands on the native height, so it is left alone.
        let sf = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(TerminalAppearance.lineSpacing(for: sf), 1)
        XCTAssertEqual(TerminalAppearance.rowHeight(for: sf, lineSpacing: 1), TerminalAppearance.nativeLineHeight(for: sf))
    }
}
