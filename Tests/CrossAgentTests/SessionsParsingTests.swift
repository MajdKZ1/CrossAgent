import XCTest
@testable import CrossAgent

final class SessionsParsingTests: XCTestCase {
    func testSessionFileMac() throws {
        let f = try XCTUnwrap(SessionFile.parse(SessionsFixtures.data("session-mac-print.json")))
        XCTAssertEqual(f.pid, 35595)
        XCTAssertEqual(f.sessionId, SessionsFixtures.background.sessionId)
        XCTAssertEqual(f.cwd, "/private/tmp/ca-sess-probe")
        XCTAssertEqual(f.procStart, "Tue Oct 27 14:39:11 2026")
        XCTAssertEqual(f.entrypoint, "sdk-cli")
        XCTAssertEqual(f.sessionStatus, .running)
        XCTAssertNil(f.tmuxSession)
        XCTAssertNil(f.userName, "derived names aren't the user's")
    }

    func testSessionFileWaitingInTmux() throws {
        let f = try XCTUnwrap(SessionFile.parse(SessionsFixtures.data("session-mac-waiting.json")))
        XCTAssertEqual(f.sessionStatus, .waiting)
        XCTAssertEqual(f.waitingFor, "permission prompt")
        XCTAssertEqual(f.tmuxSession, "caprobe")
    }

    func testSessionFilePC() throws {
        let f = try XCTUnwrap(SessionFile.parse(SessionsFixtures.data("session-pc-idle.json")))
        XCTAssertEqual(f.procStart, "6789042", "Linux procStart is /proc starttime")
        XCTAssertEqual(f.sessionStatus, .idle)
        XCTAssertEqual(f.tmuxSession, "pc-test")
        XCTAssertNil(SessionFile.parse(Data("{\"pid\":1}".utf8)))
    }

    func testProjectSlug() {
        XCTAssertEqual(ClaudePaths.projectSlug(cwd: "/private/tmp/ca-sess-probe"), "-private-tmp-ca-sess-probe")
        XCTAssertEqual(ClaudePaths.projectSlug(cwd: "/Users/me/CrossAgent"), "-Users-me-CrossAgent")
        // Seen for real: "/tmp/ca-sess-probe3_a b.c" became "-private-tmp-ca-sess-probe3-a-b-c".
        XCTAssertEqual(ClaudePaths.projectSlug(cwd: "/private/tmp/ca-sess-probe3_a b.c"), "-private-tmp-ca-sess-probe3-a-b-c")
        XCTAssertEqual(ClaudePaths.projectSlug(cwd: "/home/me/café"), "-home-me-caf-")
        XCTAssertEqual(ClaudePaths.transcript(root: "/r", cwd: "/a.b", sessionId: "s"), "/r/projects/-a-b/s.jsonl")
        XCTAssertEqual(ClaudePaths.subagentsDir(transcript: "/r/projects/-a/s.jsonl"), "/r/projects/-a/s/subagents")
        XCTAssertEqual(ClaudePaths.agentId(fileName: "agent-ad6d5aa77ae248062.jsonl"), "ad6d5aa77ae248062")
        XCTAssertEqual(ClaudePaths.agentId(fileName: "agent-asleeper-d3f7ace792f5d6fd.meta.json"), "asleeper-d3f7ace792f5d6fd")
        XCTAssertNil(ClaudePaths.agentId(fileName: "notes.txt"))
    }

    func testPSTableAndChain() {
        // Real shape of `TZ=UTC ps -axo pid=,ppid=,tty=,lstart=,comm=` for a Ghostty tab.
        let out = """
         5123  5083 ttys001  Mon Oct 26 21:46:58 2026     claude
         5083  5082 ttys001  Mon Oct 26 21:46:58 2026     -/bin/zsh
         5082  1389 ttys001  Mon Oct 26 21:46:57 2026     /usr/bin/login
         1389     1 ??       Mon Oct 26 10:00:00 2026     /Applications/Ghostty.app/Contents/MacOS/ghostty
          900     1 ??       Mon Oct  5 10:00:00 2026     /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
        """
        let t = ProcInfo.parsePS(out)
        XCTAssertEqual(t.count, 5)
        XCTAssertEqual(t[5123]?.tty, "ttys001")
        XCTAssertNil(t[1389]?.tty)
        XCTAssertEqual(t[5123]?.lstart, "Mon Oct 26 21:46:58 2026")
        XCTAssertEqual(t[900]?.lstart, "Mon Oct 5 10:00:00 2026")
        XCTAssertTrue(t[900]!.comm.hasSuffix("MacOS/Code Helper"))
        let chain = ProcInfo.ancestors(of: 5123, in: t)
        XCTAssertEqual(chain, ["-/bin/zsh", "/usr/bin/login", "/Applications/Ghostty.app/Contents/MacOS/ghostty"])
        XCTAssertTrue(ProcInfo.sameStart("Mon Oct 26 21:46:58 2026", lstart: t[5123]!.lstart))
        XCTAssertTrue(ProcInfo.sameStart("Mon Oct  5 10:00:00 2026", lstart: t[900]!.lstart), "day padding differs")
        XCTAssertFalse(ProcInfo.sameStart("Tue Oct 27 01:46:58 2026", lstart: t[5123]!.lstart), "local time is not UTC")
        XCTAssertTrue(ProcInfo.sameStart(nil, lstart: "x"))
    }

    func testLauncher() {
        let c = LauncherClassifier.classify
        XCTAssertEqual(c(["-/bin/zsh", "/usr/bin/login", "/Applications/Ghostty.app/Contents/MacOS/ghostty"], nil), .ghostty)
        XCTAssertEqual(c(["-zsh", "/usr/bin/login", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"], nil), .terminal)
        XCTAssertEqual(c(["-zsh", "/Applications/iTerm.app/Contents/MacOS/iTermServer-3.5"], nil), .iterm)
        XCTAssertEqual(c(["/bin/zsh", "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"], nil), .vscode)
        XCTAssertEqual(c(["/bin/zsh", "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"], nil), .cursor)
        XCTAssertEqual(c(["-zsh", "/Applications/Warp.app/Contents/MacOS/stable"], nil), .warp)
        XCTAssertEqual(c(["bash", "sshd-session", "sshd-session", "sshd"], nil), .ssh)
        XCTAssertEqual(c(["-zsh", "tmux"], nil), .tmux)
        XCTAssertEqual(c(["tmux: server"], "pc-test"), .tmux)
        XCTAssertEqual(c(["tmux: server"], "ca-myproj-pc-1"), .crossAgent)
        XCTAssertEqual(c([], nil), .other, "reparented to init, like a backgrounded claude -p")
        XCTAssertEqual(c(["/bin/zsh", "/Applications/CrossAgent.app/Contents/MacOS/CrossAgent"], nil), .crossAgent)
    }

    func testSubagentMeta() throws {
        let bg = try XCTUnwrap(SubagentMeta.parse(SessionsFixtures.data("background/subagents/agent-ad6d5aa77ae248062.meta.json")))
        XCTAssertEqual(bg.name, "reader")
        XCTAssertEqual(bg.toolUseId, "toolu_k3zUFjI2Ep1KDNyCeRVt0xku")
        XCTAssertEqual(bg.requestShape, "background")
        XCTAssertEqual(bg.finished, true)
        let fg = try XCTUnwrap(SubagentMeta.parse(SessionsFixtures.data("foreground/subagents/agent-ad3eded5e86b523e8.meta.json")))
        XCTAssertNil(fg.name)
        XCTAssertEqual(fg.displayName, "reader: read a.txt")
        XCTAssertEqual(fg.requestShape, "foreground")
        let tm = try XCTUnwrap(SubagentMeta.parse(SessionsFixtures.data("teammate/subagents/agent-asleeper-d3f7ace792f5d6fd.meta.json")))
        XCTAssertEqual(tm.taskKind, "in_process_teammate")
        XCTAssertNil(tm.toolUseId)
        XCTAssertNil(tm.finished)
    }

    func testTranscriptHead() {
        let bg = TranscriptHead.scan(SessionsFixtures.data("background/main.jsonl"))
        XCTAssertEqual(bg.cwd, "/private/tmp/ca-sess-probe")
        XCTAssertTrue(bg.prompt?.hasPrefix("Spawn two subagents in parallel") ?? false)
        XCTAssertNil(bg.aiTitle, "claude -p writes no ai-title")
        XCTAssertNotNil(bg.started)
        let tm = TranscriptHead.scan(SessionsFixtures.data("teammate/main.jsonl"))
        XCTAssertEqual(tm.aiTitle, "Touch made.txt in /tmp probe")
        XCTAssertEqual(tm.prompt, "Use the Bash tool to run exactly: touch /tmp/ca-sess-probe2/made.txt")
    }

    func testTitle() {
        XCTAssertEqual(SessionTitle.make(userName: "My run", aiTitle: "AI", prompt: "p", derivedName: "d", cwd: "/x"), "My run")
        XCTAssertEqual(SessionTitle.make(userName: nil, aiTitle: "AI title", prompt: "p", derivedName: "d", cwd: "/x"), "AI title")
        XCTAssertEqual(SessionTitle.make(userName: nil, aiTitle: nil, prompt: "\n**Fix** the `build`\nsecond", derivedName: "d", cwd: "/x"), "Fix the build")
        XCTAssertEqual(SessionTitle.make(userName: nil, aiTitle: nil, prompt: nil, derivedName: nil, cwd: "/a/proj"), "proj")
        let long = String(repeating: "word ", count: 40)
        XCTAssertEqual(SessionTitle.make(userName: nil, aiTitle: nil, prompt: long, derivedName: nil, cwd: "/").count, 80)
    }

    func testToolSummary() {
        XCTAssertEqual(ToolSummary.make("Bash", ["command": "swift build\nswift test"]), "Running swift build")
        XCTAssertEqual(ToolSummary.make("Read", ["file_path": "/private/tmp/ca-sess-probe/a.txt"]), "Reading a.txt")
        XCTAssertEqual(ToolSummary.make("Agent", ["name": "reader", "description": "Read a.txt"]), "Starting reader: Read a.txt")
        XCTAssertEqual(ToolSummary.make("SendMessage", ["to": "team-lead", "summary": "done"]), "Messaging team-lead: done")
        XCTAssertEqual(ToolSummary.make("mcp__figma__get_code", [:]), "Using get_code")
    }

    func testResumeScript() {
        XCTAssertEqual(SessionResume.script(sessionId: "c9bc5b47-e5f7", cwd: "/private/tmp/ca sess"),
                       "cd '/private/tmp/ca sess' && claude --resume 'c9bc5b47-e5f7'")
        XCTAssertEqual(SessionResume.script(sessionId: "x", cwd: "~/proj"), "cd \"$HOME\"/'proj' && claude --resume 'x'")
    }
}
