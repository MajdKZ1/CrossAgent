import XCTest
@testable import CrossAgent

final class CommandBuilderTests: XCTestCase {
    let mac = HostStore.defaults[0]
    let pc = HostStore.defaults[1]

    func testSessionNameValidation() {
        XCTAssertTrue(SessionName.isValid("ca-pc-1"))
        XCTAssertTrue(SessionName.isValid(String(repeating: "a", count: 64)))
        XCTAssertFalse(SessionName.isValid(""))
        XCTAssertFalse(SessionName.isValid(String(repeating: "a", count: 65)))
        XCTAssertFalse(SessionName.isValid("a b"))
        XCTAssertFalse(SessionName.isValid("a;rm"))
    }

    func testLocalClaude() {
        let c = CommandBuilder.command(host: mac, mode: .claude, session: "ca-mac-1", localShell: "/bin/zsh")
        XCTAssertEqual(c.executable, "/bin/zsh")
        XCTAssertEqual(c.args[0], "-lc")
        XCTAssertTrue(c.args[1].hasSuffix("if command -v tmux >/dev/null 2>&1; then export CROSSAGENT_CLIENT=1; exec tmux new -A -s ca-mac-1 claude \\; set -q status off \\; set -q mouse on \\; set -sq focus-events on \\; set -q prefix None \\; set -q prefix2 None \\; set -sq set-clipboard on; else exec claude; fi"))
    }

    func testLocalShell() {
        let c = CommandBuilder.command(host: mac, mode: .shell, session: "ca-mac-2", localShell: "/bin/zsh")
        XCTAssertTrue(c.args[1].hasSuffix("if command -v tmux >/dev/null 2>&1; then export CROSSAGENT_CLIENT=1; exec tmux new -A -s ca-mac-2 \\; set -q status off \\; set -q mouse on \\; set -sq focus-events on \\; set -q prefix None \\; set -q prefix2 None \\; set -sq set-clipboard on; else exec \"$SHELL\" -l; fi"))
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
        XCTAssertTrue(remote.hasSuffix("then export CROSSAGENT_CLIENT=1; exec tmux new -A -s ca-pc-1 claude \\; set -q status off \\; set -q mouse on \\; set -sq focus-events on \\; set -q prefix None \\; set -q prefix2 None \\; set -sq set-clipboard on; else exec claude; fi'"))
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

    // MARK: Project cwd and env

    func testNextFreeSessionName() {
        XCTAssertEqual(SessionName.nextFree(slug: "app", host: "pc", used: []), "ca-app-pc-1")
        XCTAssertEqual(SessionName.nextFree(slug: "app", host: "pc", used: ["ca-app-pc-1", "ca-pc-2", "ca-app-pc-3"]), "ca-app-pc-2")
    }

    func testShellPath() {
        XCTAssertEqual(CommandBuilder.shellPath("$HOME/Projects/my app"), #""$HOME"/'Projects/my app'"#)
        XCTAssertEqual(CommandBuilder.shellPath("~/it's"), #""$HOME"/'it'\''s'"#)
        XCTAssertEqual(CommandBuilder.shellPath("$HOME"), #""$HOME""#)
        XCTAssertEqual(CommandBuilder.shellPath("/Users/me/x"), "'/Users/me/x'")
        XCTAssertEqual(CommandBuilder.shellPath("$HOMEx/a"), "'$HOMEx/a'")
    }

    func testLocalClaudeWithCwdAndEnv() {
        let c = CommandBuilder.command(host: mac, mode: .claude, session: "ca-app-mac-1", cwd: "/Users/me/my app",
                                       env: ["CROSSAGENT_ROLE": "orchestrator", "CROSSAGENT_PROJECT": "app"],
                                       localShell: "/bin/zsh")
        XCTAssertTrue(c.args[1].hasSuffix("then export CROSSAGENT_CLIENT=1; exec tmux new -A -s ca-app-mac-1 -c '/Users/me/my app' -e 'CROSSAGENT_PROJECT=app' -e 'CROSSAGENT_ROLE=orchestrator' claude \\; set -q status off \\; set -q mouse on \\; set -sq focus-events on \\; set -q prefix None \\; set -q prefix2 None \\; set -sq set-clipboard on; else cd '/Users/me/my app' 2>/dev/null; export 'CROSSAGENT_PROJECT=app'; export 'CROSSAGENT_ROLE=orchestrator'; exec claude; fi"), c.args[1])
    }

    func testSSHShellWithHomeRelativeCwd() {
        let c = CommandBuilder.command(host: pc, mode: .shell, session: "ca-app-pc-2", cwd: "$HOME/Projects/app",
                                       env: ["CROSSAGENT_PROJECT": "app", "bad key": "x"])
        let remote = c.args.last!
        XCTAssertTrue(remote.hasPrefix("exec $SHELL -lc '"))
        XCTAssertFalse(remote.contains("bad key"))
        // The inner script, after the outer single quotes are undone by the remote shell.
        let inner = CommandBuilder.script(mode: .shell, session: "ca-app-pc-2", cwd: "$HOME/Projects/app",
                                          env: ["CROSSAGENT_PROJECT": "app"])
        XCTAssertEqual(remote, "exec $SHELL -lc " + CommandBuilder.shellQuote(inner))
        XCTAssertTrue(inner.contains(#"exec tmux new -A -s ca-app-pc-2 -c "$HOME"/'Projects/app' -e 'CROSSAGENT_PROJECT=app' \; set -q status off"#), inner)
        XCTAssertTrue(inner.contains(#"else cd "$HOME"/'Projects/app' 2>/dev/null; export 'CROSSAGENT_PROJECT=app'; exec "$SHELL" -l; fi"#), inner)
    }

    func testAttachOnly() {
        let s = CommandBuilder.script(mode: .claude, session: "ca-app-pc-tests", cwd: "/x", env: ["A": "b"], attachOnly: true)
        XCTAssertTrue(s.hasSuffix("then export CROSSAGENT_CLIENT=1; exec tmux attach -t '=ca-app-pc-tests' \\; set -q status off \\; set -q mouse on \\; set -sq focus-events on \\; set -q prefix None \\; set -q prefix2 None \\; set -sq set-clipboard on; else echo 'tmux is not installed here' >&2; exit 1; fi"), s)
        XCTAssertFalse(s.contains("new "))
        XCTAssertFalse(s.contains(" claude"))
    }

    func testKillMatchesExactName() {
        let c = CommandBuilder.killCommand(host: mac, session: "ca-pc-1")
        XCTAssertTrue(c.args.last!.contains("tmux kill-session -t '=ca-pc-1'"))
    }

    /// Runs the fallback branch (no tmux on PATH) through a real sh to check quoting:
    /// it must land in the folder with the env set.
    func testFallbackRunsInCwdWithEnv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca it's \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var script = CommandBuilder.script(mode: .shell, session: "ca-t-mac-1", cwd: dir.path,
                                           env: ["CROSSAGENT_PROJECT": "a b'c"])
        script = script.replacingOccurrences(of: "command -v tmux", with: "command -v no-such-tmux-here")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["SHELL": "/bin/sh", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let input = Pipe(), out = Pipe()
        p.standardInput = input
        p.standardOutput = out
        try p.run()
        input.fileHandleForWriting.write(Data("pwd; printf '%s\\n' \"$CROSSAGENT_PROJECT\"; exit\n".utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [dir.path, "a b'c"])
    }
}
