import XCTest
@testable import CrossAgent

@MainActor
final class SessionsUITests: XCTestCase {
    private func makeApp() -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-sess-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "ca-sess-\(UUID().uuidString)")!
        return AppState(hosts: HostStore.example, store: ProjectStore(defaults: defaults, stateDir: dir))
    }

    private func session(_ host: String, _ sid: String, cwd: String, pid: Int32? = nil, tmux: String? = nil,
                         launcher: SessionLauncher = .ended) -> ClaudeSession {
        ClaudeSession(hostId: host, sessionId: sid, cwd: cwd, pid: pid, tty: nil, launcher: launcher, tmuxSession: tmux,
                      transcriptPath: "/x/\(sid).jsonl", title: "Fix the thing", status: pid == nil ? .ended : .running,
                      startedAt: Date(), lastActivity: Date(), subagentCount: 0)
    }

    func testProjectFilterMatchesFolderAndPCCopy() {
        let p = Project(path: "/Users/me/Code/app", home: "/Users/me", config: nil)
        XCTAssertEqual(p.pcRelativePath, "Code/app")
        XCTAssertTrue(AppState.cwd("/Users/me/Code/app", isIn: p, local: true))
        XCTAssertTrue(AppState.cwd("/Users/me/Code/app/web", isIn: p, local: true))
        XCTAssertFalse(AppState.cwd("/Users/me/Code/app2", isIn: p, local: true))
        XCTAssertFalse(AppState.cwd("/Users/me/Code", isIn: p, local: true))
        XCTAssertTrue(AppState.cwd("/home/me/Code/app", isIn: p, local: false))
        XCTAssertTrue(AppState.cwd("/home/me/Code/app/x", isIn: p, local: false))
        XCTAssertFalse(AppState.cwd("/home/me/Code/app2", isIn: p, local: false))
        XCTAssertFalse(AppState.cwd("/srv/Code/app", isIn: p, local: false))
    }

    func testGroupsByFolderAcrossHomes() {
        let list = [session("mac", "a", cwd: "/Users/me/x", pid: 1), session("pc", "b", cwd: "/home/me/y"),
                    session("pc", "c", cwd: "/home/me/x")]
        let g = SessionsTab.groups(list)
        XCTAssertEqual(g.map(\.path), ["~/x", "~/y"])
        XCTAssertEqual(g[0].sessions.map(\.sessionId), ["a", "c"])
        XCTAssertEqual(g[0].name, "x")
    }

    func testLookWords() {
        XCTAssertEqual(SessionLook.short(42), "42s")
        XCTAssertEqual(SessionLook.short(7300), "2h")
        let now = Date()
        var s = session("mac", "a", cwd: "/x")
        s.lastActivity = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(SessionLook.age(s, now: now), "ended 3h ago")
        s = session("mac", "a", cwd: "/x", pid: 5, tmux: "work", launcher: .tmux)
        XCTAssertEqual(SessionLook.place(s), "tmux work")
        XCTAssertEqual(AppState.shortTitle(String(repeating: "a", count: 60)).count, 40)
    }

    func testOpenModes() {
        XCTAssertEqual(session("mac", "a", cwd: "/x", pid: 3, tmux: "m20plain", launcher: .tmux).openMode, .attach(tmux: "m20plain"))
        XCTAssertEqual(session("mac", "a", cwd: "/x", pid: 3, launcher: .ghostty).openMode, .watch)
        XCTAssertEqual(session("mac", "a", cwd: "/x").openMode, .transcript)
    }

    func testAnyTmuxNameAttachesQuoted() {
        XCTAssertTrue(SessionName.isAttachable("my work 2"))
        XCTAssertTrue(SessionName.isAttachable("it's"))
        XCTAssertFalse(SessionName.isAttachable("a:b"))
        XCTAssertFalse(SessionName.isAttachable("a.b"))
        XCTAssertFalse(SessionName.isAttachable(""))
        XCTAssertFalse(SessionName.isAttachable("a\nb"))
        let s = CommandBuilder.script(mode: .shell, session: "it's mine", attachOnly: true)
        XCTAssertTrue(s.contains("exec tmux attach -t '=it'\\''s mine' \\;"), s)
    }

    func testResumeProgramRunsInsteadOfClaude() {
        let line = SessionResume.script(sessionId: "abc-123", cwd: "/home/me/x")
        let s = CommandBuilder.script(mode: .claude, session: "ca-x-pc-resume-abc123", cwd: "/home/me/x", program: line)
        XCTAssertTrue(s.contains("tmux new -A -s ca-x-pc-resume-abc123 -c '/home/me/x' 'cd '\\''/home/me/x'\\'' && claude --resume '\\''abc-123'\\'''"), s)
        XCTAssertTrue(s.contains("exec sh -c 'cd "), s)
        // Without a program nothing changes.
        XCTAssertTrue(CommandBuilder.script(mode: .claude, session: "ca-pc-1").contains("tmux new -A -s ca-pc-1 claude \\;"))
    }

    func testResumeNameAndTitles() {
        let app = makeApp()
        app.project = Project(path: "/tmp/ca-sess-x", home: "/tmp", config: nil)
        let pc = app.host("pc")!
        XCTAssertEqual(app.resumeSessionName(host: pc, sessionId: "1f2e3d4c-aaaa"), "ca-ca-sess-x-pc-resume-1f2e3d")
        let tab = Tab(kind: .agent(.session(host: "pc", name: "ca-ca-sess-x-pc-resume-1f2e3d")), title: "Fix the thing")
        XCTAssertEqual(app.title(of: tab), "Fix the thing")
        let plain = Tab(kind: .agent(.session(host: "pc", name: "ca-ca-sess-x-pc-build")))
        XCTAssertEqual(app.title(of: plain), "build")
    }

    func testClaudeTabsRestoreOnlyForKnownHosts() {
        let app = makeApp()
        let saved = [Tab(kind: .agent(.claude(host: "pc", sessionId: "s1")), title: "Watch me", id: "c1"),
                     Tab(kind: .agent(.claude(host: "gone", sessionId: "s2")), id: "c2"),
                     Tab(kind: .agent(.session(host: "mac", name: "my work")), id: "t")]
        app.restoreTabs(ProjectState(tabs: saved, selectedTab: "c1"))
        XCTAssertEqual(app.tabs.map(\.id).filter { $0 != app.tabs[0].id }, ["c1", "t"])
        XCTAssertEqual(app.tabs.first { $0.id == "c1" }?.icon, "eye")
        XCTAssertEqual(app.tabs.first { $0.id == "c1" }?.title, "Watch me")
        XCTAssertEqual(app.mode, .agent)
    }

    func testTwoIdleNoticesInOneLineFinishBoth() throws {
        let text = """
        Another Claude session sent a message:
        <teammate-message teammate_id="beta" color="green">
        {"type":"idle_notification","from":"beta","idleReason":"available","result":"done"}
        </teammate-message>

        <teammate-message teammate_id="alpha" color="blue">
        {"type":"idle_notification","from":"alpha","idleReason":"available","result":"done"}
        </teammate-message>
        """
        let line: [String: Any] = ["type": "user", "uuid": "u1", "timestamp": "2026-10-27T15:26:41.500Z",
                                   "message": ["role": "user", "content": text]]
        var p = TranscriptParser(agentId: nil, includeThinking: false)
        let items = p.parse(try JSONSerialization.data(withJSONObject: line))
        XCTAssertEqual(items.map(\.signal), [.teammateIdle(name: "beta", result: "done"), .teammateIdle(name: "alpha", result: "done")])
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    func testLiveTabsDedupe() {
        let app = makeApp()
        app.project = Project(path: "/tmp/ca-sess-y", home: "/tmp", config: nil)
        app.restoreTabs(ProjectState())
        app.openClaudeLive(host: "pc", sessionId: "s1", title: "A long running refactor")
        app.openClaudeLive(host: "pc", sessionId: "s1", title: "Other")
        let live = app.tabs.filter { $0.kind == .agent(.claude(host: "pc", sessionId: "s1")) }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.title, "A long running refactor")
        XCTAssertEqual(app.selectedTab?.id, live.first?.id)
    }
}
