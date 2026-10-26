import XCTest
@testable import CrossAgent

final class CommandBuilderTests: XCTestCase {
    let mac = HostStore.defaults[0]
    let pc = HostStore.defaults[1]

    func testSessionNameValidation() {
        XCTAssertTrue(SessionName.isValid("ca-pc-1"))
        XCTAssertTrue(SessionName.isValid(String(repeating: "a", count: 40)))
        XCTAssertFalse(SessionName.isValid(""))
        XCTAssertFalse(SessionName.isValid(String(repeating: "a", count: 41)))
        XCTAssertFalse(SessionName.isValid("a b"))
        XCTAssertFalse(SessionName.isValid("a;rm"))
    }

    func testLocalClaude() {
        let c = CommandBuilder.command(host: mac, mode: .claude, session: "ca-mac-1", localShell: "/bin/zsh")
        XCTAssertEqual(c.executable, "/bin/zsh")
        XCTAssertEqual(c.args[0], "-lc")
        XCTAssertTrue(c.args[1].hasSuffix("if command -v tmux >/dev/null 2>&1; then exec tmux new -A -s ca-mac-1 claude \\; set -q status off \\; set -sq focus-events on; else exec claude; fi"))
    }

    func testLocalShell() {
        let c = CommandBuilder.command(host: mac, mode: .shell, session: "ca-mac-2", localShell: "/bin/zsh")
        XCTAssertTrue(c.args[1].hasSuffix("if command -v tmux >/dev/null 2>&1; then exec tmux new -A -s ca-mac-2 \\; set -q status off \\; set -sq focus-events on; else exec \"$SHELL\" -l; fi"))
    }

    func testSSHClaude() {
        let c = CommandBuilder.command(host: pc, mode: .claude, session: "ca-pc-1")
        XCTAssertEqual(c.executable, "/usr/bin/ssh")
        XCTAssertEqual(c.args.first, "-tt")
        XCTAssertTrue(c.args.contains("ServerAliveInterval=15"))
        XCTAssertTrue(c.args.contains("ServerAliveCountMax=3"))
        XCTAssertEqual(c.args[c.args.count - 2], "pc")
        let remote = c.args.last!
        XCTAssertTrue(remote.hasPrefix("exec $SHELL -lc '"))
        XCTAssertTrue(remote.hasSuffix("then exec tmux new -A -s ca-pc-1 claude \\; set -q status off \\; set -sq focus-events on; else exec claude; fi'"))
    }

    func testQuoteRoundTripsThroughSh() throws {
        let script = CommandBuilder.script(mode: .shell, session: "x")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s " + CommandBuilder.shellQuote(script)]
        let out = Pipe()
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), script)
    }

    func testQuoteEscapesSingleQuotes() {
        XCTAssertEqual(CommandBuilder.shellQuote("it's"), "'it'\\''s'")
    }
}
