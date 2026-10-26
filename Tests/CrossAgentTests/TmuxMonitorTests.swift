import XCTest
@testable import CrossAgent

final class TmuxMonitorTests: XCTestCase {
    let m = "@@ca-test1234"

    // Real Claude Code 2.1.310 screens (trimmed), captured from tmux.
    let claudeIdle = """
     \u{1B}[38;5;174m▐▛███▛█\u{1B}[39m   \u{1B}[1mClaude Code\u{1B}[0m v2.1.310
    ▝▜██████▀  Opus 5.5 with medium effort · Claude Max
    ✻ Worked for 3s · done 2:11 AM
    ────────────────────────────────────────
    ❯
    ────────────────────────────────────────
      Opus 5.5 · medium · 5h 4% (3h 58m) · 7d 35% · $0.23
      ⏸ manual mode on
    """
    let claudeBusy = """
    ❯ Write a 300 word poem about tmux. Do not use any tools.
    \u{1B}[38;5;174m✻\u{1B}[39m \u{1B}[38;5;174mInfusing…\u{1B}[39m (11s · still thinking with medium effort)
      ⎿  Tip: Use /theme to change the color theme
    ────────────────────────────────────────
    ❯
    ────────────────────────────────────────
      ⏸ manual mode on
    """
    let claudeBusyShort = """
    ❯ Run this exact shell command
    · Nucleating…
    ────────────────────────────────────────
    ❯
    ────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle)
    """
    let claudePermission = """
     Bash command
     curl -sI https://example.com | head -1
     This command requires approval
     Do you want to proceed?
     \u{1B}[38;5;153m❯ 1. Yes\u{1B}[39m
       2. Yes, and don’t ask again for: curl -sI https://example.com
       4. No
     Esc to cancel · Tab to amend
    """
    let claudeTrust = """
     Quick safety check: Is this a project you created or one you trust?
     \u{1B}[38;5;153m❯\u{1B}[39m \u{1B}[38;5;153mNo,\u{1B}[39m exit
       Yes, I trust this folder
     \u{1B}[38;5;246mEnter\u{1B}[39m to confirm · Esc to cancel
    """

    // MARK: status

    func testDeadPaneIsExited() {
        XCTAssertEqual(SessionDetector.status(previous: nil, current: claudeBusy, command: "claude", paneDead: true), .exited)
    }

    func testClaudeStates() {
        XCTAssertEqual(SessionDetector.status(previous: nil, current: claudeIdle, command: "2.1.310", paneDead: false), .idle)
        XCTAssertEqual(SessionDetector.status(previous: nil, current: claudeBusy, command: "claude", paneDead: false), .running)
        XCTAssertEqual(SessionDetector.status(previous: nil, current: claudeBusyShort, command: "claude", paneDead: false), .running)
        XCTAssertEqual(SessionDetector.status(previous: nil, current: claudePermission, command: "claude", paneDead: false), .waitingForInput)
        XCTAssertEqual(SessionDetector.status(previous: nil, current: claudeTrust, command: "2.1.310", paneDead: false), .waitingForInput)
        XCTAssertEqual(SessionDetector.status(previous: nil, current: "esc to interrupt", command: "claude", paneDead: false), .running)
    }

    func testClaudeIdleFooterRedrawIsNotRunning() {
        let redrawn = claudeIdle.replacingOccurrences(of: "(3h 58m)", with: "(3h 57m)")
        XCTAssertEqual(SessionDetector.status(previous: claudeIdle, current: redrawn, command: "claude", paneDead: false), .idle)
    }

    func testDoneLineIsNotBusy() {
        XCTAssertFalse(SessionDetector.isBusyLine("✻ Worked for 3s · done 2:11 AM"))
        XCTAssertFalse(SessionDetector.isBusyLine(" ▝▝   ▝▝   /…/tmp/x"))
        XCTAssertTrue(SessionDetector.isBusyLine("✳ Bunning… (4s · ↓ 227 tokens · thought for 1s)"))
    }

    func testShellAndOtherPrograms() {
        XCTAssertEqual(SessionDetector.status(previous: "a", current: "b", command: "zsh", paneDead: false), .idle)
        XCTAssertEqual(SessionDetector.status(previous: "top 1", current: "top 2", command: "top", paneDead: false), .running)
        XCTAssertEqual(SessionDetector.status(previous: "top 1", current: "top 1", command: "top", paneDead: false), .idle)
        XCTAssertEqual(SessionDetector.status(previous: nil, current: "x", command: "top", paneDead: false), .idle)
    }

    func testIsClaude() {
        XCTAssertTrue(SessionDetector.isClaude(command: "claude", capture: ""))
        XCTAssertTrue(SessionDetector.isClaude(command: "2.1.310", capture: ""))
        XCTAssertTrue(SessionDetector.isClaude(command: "node", capture: claudeIdle))
        XCTAssertFalse(SessionDetector.isClaude(command: "zsh", capture: "$ ls"))
        XCTAssertFalse(SessionDetector.isClaudeCodeProcess("/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertTrue(SessionDetector.isClaudeCodeProcess("/Users/x/.local/bin/claude"))
    }

    func testStatusWithoutCapture() {
        let now = Date(timeIntervalSince1970: 1000)
        var prev = info(status: .waitingForInput, activity: 900)
        XCTAssertEqual(SessionDetector.statusWithoutCapture(previous: prev, lastActivity: prev.lastActivity, paneDead: false, now: now), .waitingForInput)
        XCTAssertEqual(SessionDetector.statusWithoutCapture(previous: prev, lastActivity: Date(timeIntervalSince1970: 998), paneDead: false, now: now), .running)
        prev.status = .running
        XCTAssertEqual(SessionDetector.statusWithoutCapture(previous: prev, lastActivity: Date(timeIntervalSince1970: 950), paneDead: false, now: now), .idle)
        XCTAssertEqual(SessionDetector.statusWithoutCapture(previous: nil, lastActivity: now, paneDead: true, now: now), .exited)
    }

    func testStripANSI() {
        let s = "\u{1B}[1mbold\u{1B}[0m \u{1B}]8;id=x;https://a.b\u{1B}\\link\u{1B}]8;;\u{1B}\\ \u{1B}[38;5;220mc"
        XCTAssertEqual(SessionDetector.stripANSI(s), "bold link c")
    }

    // MARK: parser

    func testParseFullOutput() {
        let text = """
        \(m) now 1793052700
        \(m) panes
        ca-mac-1\t1\t17277\t0\t1793052596\t1793052596\t1793052690\t1\t120\t40\t2.1.310
        ca-pc-shell\t0\t500\t0\t1793052000\t1793052000\t1793052001\t0\t80\t24\tzsh
        ca-pc-shell\t1\t501\t0\t1793052000\t1793052000\t1793052005\t0\t80\t24\ttop
        garbage line
        \(m) cap ca-mac-1
        \(claudeBusy)

        \(m) cap ca-pc-shell
        top line 1
        \(m) ps
          PID  PPID ELAPSED COMM
            1     0 10-02:03:04 /sbin/launchd
        17276     1    00:33 tmux
        17277 17276    01:00 claude
        17300 17277    00:20 claude
          900   800 01:02:03 /Users/x/.local/bin/claude
          950   900    00:05 node
          960     1    00:07 /Applications/Claude.app/Contents/MacOS/Claude
        \(m) cwd
        p17277
        fcwd
        n/tmp/probe
        p900
        fcwd
        n/Users/x/proj with space
        \(m) end

        """
        let out = TmuxPoll.parse(text, marker: m)
        XCTAssertTrue(out.complete)
        XCTAssertEqual(out.hostNow, 1793052700)
        XCTAssertEqual(out.panes.count, 3)
        XCTAssertEqual(out.panes[0].command, "2.1.310")
        XCTAssertEqual(out.panes[0].activity, 1793052690)
        XCTAssertEqual(out.captures["ca-mac-1"], claudeBusy + "\n")
        XCTAssertEqual(out.captures["ca-pc-shell"], "top line 1")
        XCTAssertEqual(out.cwds[900], "/Users/x/proj with space")
        XCTAssertEqual(out.procs.first { $0.pid == 1 }?.elapsed, 871384.0) // 10-02:03:04

        let sessions = TmuxPoll.sessions(hostId: "mac", output: out, previous: [:], clockOffset: 0, withCaptures: true)
        XCTAssertEqual(sessions.map(\.name), ["ca-pc-shell", "ca-mac-1"])
        let claude = sessions[1]
        XCTAssertEqual(claude.id, "mac/ca-mac-1")
        XCTAssertTrue(claude.isClaude)
        XCTAssertEqual(claude.status, .running)
        XCTAssertEqual(claude.attachedClients, 1)
        XCTAssertEqual(claude.cols, 120)
        XCTAssertEqual(claude.rows, 40)
        XCTAssertEqual(claude.createdAt, Date(timeIntervalSince1970: 1793052596))
        // Active pane wins for multi pane sessions.
        XCTAssertEqual(sessions[0].currentCommand, "top")

        let ext = TmuxPoll.externalClaudes(hostId: "mac", output: out)
        XCTAssertEqual(ext, [ExternalClaude(hostId: "mac", pid: 900, elapsed: 3723, cwd: "/Users/x/proj with space")])
    }

    func testNoTmuxServerIsEmptyNotError() {
        let out = TmuxPoll.parse("\(m) now 5\n\(m) panes\n\(m) end\n", marker: m)
        XCTAssertTrue(out.complete)
        XCTAssertTrue(TmuxPoll.sessions(hostId: "pc", output: out, previous: [:], clockOffset: 0, withCaptures: true).isEmpty)
    }

    func testTruncatedOutputIsIncomplete() {
        XCTAssertFalse(TmuxPoll.parse("\(m) now 5\n\(m) panes\n", marker: m).complete)
        XCTAssertFalse(TmuxPoll.parse("", marker: m).complete)
    }

    func testSlowPollKeepsPreviousCapture() {
        let out = TmuxPoll.parse("\(m) panes\nca-a\t1\t1\t0\t100\t100\t100\t0\t80\t24\tclaude\n\(m) end\n", marker: m)
        var prev = info(status: .waitingForInput, activity: 100)
        prev.name = "ca-a"
        prev.capture = claudePermission
        let s = TmuxPoll.sessions(hostId: "mac", output: out, previous: ["ca-a": prev], clockOffset: 0, withCaptures: false)
        XCTAssertEqual(s.first?.capture, claudePermission)
        XCTAssertEqual(s.first?.status, .waitingForInput)
    }

    func testClockOffsetShiftsDates() {
        let out = TmuxPoll.parse("\(m) panes\nca-a\t1\t1\t0\t100\t100\t100\t0\t80\t24\tzsh\n\(m) end\n", marker: m)
        let s = TmuxPoll.sessions(hostId: "pc", output: out, previous: [:], clockOffset: 50, withCaptures: true)
        XCTAssertEqual(s.first?.createdAt, Date(timeIntervalSince1970: 150))
    }

    func testElapsedFormats() {
        XCTAssertEqual(TmuxPoll.parseElapsed("00:05"), 5)
        XCTAssertEqual(TmuxPoll.parseElapsed("01:02:03"), 3723)
        XCTAssertEqual(TmuxPoll.parseElapsed("2-00:00:01"), 172801)
        XCTAssertNil(TmuxPoll.parseElapsed("abc"))
    }

    func testScriptRunsInShWithoutTmuxServer() {
        // Points tmux at an empty socket dir so no server exists.
        let script = "export TMUX_TMPDIR=$(mktemp -d); " + TmuxPoll.script(marker: m, captures: true, processes: true)
        for shell in ["/bin/sh", "/bin/zsh"] {
            let r = Runner.runSync(SpawnCommand(executable: shell, args: ["-c", script]))
            let out = TmuxPoll.parse(r.stdout, marker: m)
            XCTAssertTrue(out.complete, "\(shell): \(r.stderr)")
            XCTAssertTrue(out.panes.isEmpty)
            XCTAssertFalse(out.procs.isEmpty)
        }
    }

    // MARK: integration (CA_INTEGRATION=1 swift test --filter TmuxMonitorTests/testLiveHosts)

    func testLiveHosts() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CA_INTEGRATION"] == "1")
        for host in HostStore.defaults {
            for fast in [false, true] {
                let r = await TmuxMonitor.fetch(host: host, fast: fast, previous: [:])
                print("[\(host.id)] fast=\(fast) \(String(format: "%.2f", r.duration))s error=\(r.error ?? "none")")
                for s in r.sessions {
                    let lastLine = SessionDetector.bottomLines(SessionDetector.stripANSI(s.capture), count: 1).first ?? ""
                    print("  \(s.id) cmd=\(s.currentCommand) claude=\(s.isClaude) status=\(s.status) \(s.cols)x\(s.rows) up=\(Int(s.runningFor))s attached=\(s.attachedClients) capture=\(s.capture.utf8.count)B last=\(lastLine.prefix(60))")
                }
                for e in r.external { print("  external pid=\(e.pid) up=\(Int(e.elapsed))s cwd=\(e.cwd ?? "?")") }
                XCTAssertNil(r.error)
            }
        }
    }

    @MainActor
    func testLiveMonitor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CA_INTEGRATION"] == "1")
        let mon = TmuxMonitor(hosts: HostStore.defaults)
        mon.setActive(true)
        mon.start()
        try await Task.sleep(nanoseconds: 6_000_000_000)
        mon.stop()
        for h in HostStore.defaults {
            print("[\(h.id)] reachable=\(mon.reachable[h.id] ?? false) poll=\(String(format: "%.2f", mon.lastPollDuration[h.id] ?? -1))s free=\(mon.freeSessionName(host: h))")
            for s in mon.sessions[h.id] ?? [] { print("  \(s.id) cmd=\(s.currentCommand) status=\(s.status)") }
            XCTAssertEqual(mon.reachable[h.id], true)
        }
    }

    private func info(status: SessionStatus, activity: TimeInterval) -> TmuxSessionInfo {
        TmuxSessionInfo(hostId: "mac", name: "ca-x", createdAt: Date(timeIntervalSince1970: 0),
                        lastActivity: Date(timeIntervalSince1970: activity), currentCommand: "claude",
                        paneDead: false, attachedClients: 0, cols: 80, rows: 24, capture: "",
                        status: status, isClaude: true)
    }
}
