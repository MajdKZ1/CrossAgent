import XCTest
@testable import CrossAgent

@MainActor
final class SessionsDiscoveryTests: XCTestCase {
    private var root: URL!
    private let mac = Host(id: "mac", name: "This Mac", type: .local, target: nil, accent: "#6ea8fe")
    private let pc = Host(id: "pc", name: "Linux PC", type: .ssh, target: "pc", accent: "#5fd39a")
    static let python = "/usr/bin/python3"

    override func setUp() async throws {
        root = try SessionsFixtures.makeRoot()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSession(pid: Int32, _ s: SessionsFixtures.Sample, status: String, extra: String = "") throws {
        let json = #"{"pid":\#(pid),"sessionId":"\#(s.sessionId)","cwd":"\#(s.cwd)","startedAt":1793111951891,"procStart":"Mon Oct 26 21:46:58 2026","name":"probe-b5","nameSource":"derived","status":"\#(status)","statusUpdatedAt":1793111952232\#(extra)}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("sessions/\(pid).json"))
    }

    /// A fake process table: this test process in a Ghostty tab.
    private func scanner(lstart: String = "Mon Oct 26 21:46:58 2026",
                         clients: [(pid: Int32, session: String)] = []) -> LocalSessionScanner {
        let me = getpid()
        return LocalSessionScanner(root: root.path, processes: {
            [me: ProcInfo(pid: me, ppid: 70001, tty: "ttys009", lstart: lstart, comm: "claude"),
             70001: ProcInfo(pid: 70001, ppid: 70002, tty: "ttys009", lstart: lstart, comm: "-/bin/zsh"),
             70002: ProcInfo(pid: 70002, ppid: 1, tty: nil, lstart: lstart, comm: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
             // tmux clients: one in Ghostty, one in Terminal, one CrossAgent pane, one over ssh.
             71001: ProcInfo(pid: 71001, ppid: 70001, tty: "ttys009", lstart: lstart, comm: "tmux"),
             71002: ProcInfo(pid: 71002, ppid: 71012, tty: "ttys010", lstart: lstart, comm: "tmux"),
             71012: ProcInfo(pid: 71012, ppid: 71022, tty: "ttys010", lstart: lstart, comm: "-zsh"),
             71022: ProcInfo(pid: 71022, ppid: 1, tty: nil, lstart: lstart, comm: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
             71003: ProcInfo(pid: 71003, ppid: 71013, tty: "ttys011", lstart: lstart, comm: "tmux"),
             71013: ProcInfo(pid: 71013, ppid: 1, tty: nil, lstart: lstart, comm: "/Applications/CrossAgent.app/Contents/MacOS/CrossAgent"),
             71004: ProcInfo(pid: 71004, ppid: 71014, tty: "ttys012", lstart: lstart, comm: "tmux"),
             71014: ProcInfo(pid: 71014, ppid: 71024, tty: "ttys012", lstart: lstart, comm: "-zsh"),
             71024: ProcInfo(pid: 71024, ppid: 1, tty: nil, lstart: lstart, comm: "sshd-session")]
        }, tmuxPanes: { [:] }, tmuxClients: { clients })
    }

    func testLocalScanner() throws {
        let bg = SessionsFixtures.background
        try writeSession(pid: getpid(), bg, status: "waiting", extra: #","waitingFor":"permission prompt""#)
        // A stale file from a crashed session: its pid is gone.
        try writeSession(pid: 999_999, SessionsFixtures.teammate, status: "busy")
        let s = scanner()
        let run = s.running()
        XCTAssertEqual(run.count, 1)
        let r = try XCTUnwrap(run.first)
        XCTAssertEqual(r.sid, bg.sessionId)
        XCTAssertEqual(r.tty, "ttys009")
        XCTAssertEqual(r.subagents, 2)
        XCTAssertEqual(r.path, root.path + "/projects/-private-tmp-ca-sess-probe/\(bg.sessionId).jsonl")
        XCTAssertNotNil(r.mtime)
        let session = ClaudeSession.make(hostId: "mac", raw: r)
        XCTAssertEqual(session.launcher, .ghostty)
        XCTAssertEqual(session.status, .waiting)
        XCTAssertEqual(session.openMode, .watch)
        XCTAssertTrue(session.title.hasPrefix("Spawn two subagents"), session.title)

        let rec = s.recent(days: 7, excluding: Set(run.map(\.sid)))
        XCTAssertEqual(Set(rec.map(\.sid)), [SessionsFixtures.teammate.sessionId, SessionsFixtures.foreground.sessionId])
        let tm = ClaudeSession.make(hostId: "mac", raw: rec.first { $0.sid == SessionsFixtures.teammate.sessionId }!)
        XCTAssertEqual(tm.title, "Touch made.txt in /tmp probe")
        XCTAssertEqual(tm.cwd, "/private/tmp/ca-sess-probe2", "from the transcript head")
        XCTAssertEqual(tm.status, .ended)
        XCTAssertEqual(tm.openMode, .transcript)
        XCTAssertEqual(tm.subagentCount, 1)
        XCTAssertEqual(s.recent(days: 7, excluding: [], now: Date().addingTimeInterval(8 * 86400)).count, 0)
    }

    /// Claude Code parks old copies as `<id>.orphaned-<ts>-<hex>.jsonl`; they aren't sessions.
    func testOrphanedTranscriptsAreSkipped() throws {
        let fg = SessionsFixtures.foreground
        let dir = root.appendingPathComponent("projects/-private-tmp-ca-sess-probe")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("\(fg.sessionId).orphaned-1792659203960-26ba07f0.jsonl"))
        let ids = scanner().recent(days: 7, excluding: []).map(\.sid)
        XCTAssertFalse(ids.contains { $0.contains("orphaned") }, "\(ids)")
    }

    func testPidReuseIsNotASession() throws {
        try writeSession(pid: getpid(), SessionsFixtures.background, status: "busy")
        XCTAssertEqual(scanner(lstart: "Tue Oct 27 09:00:00 2026").running().count, 0)
    }

    func testTmuxFromSessionFile() throws {
        try writeSession(pid: getpid(), SessionsFixtures.background, status: "idle", extra: #","tmux":"ca-proj-mac-orch:@0.%0""#)
        let r = try XCTUnwrap(scanner().running().first)
        let s = ClaudeSession.make(hostId: "mac", raw: r)
        XCTAssertEqual(s.launcher, .crossAgent)
        XCTAssertEqual(s.openMode, .attach(tmux: "ca-proj-mac-orch"))
    }

    // MARK: Viewers

    func testViewersFromTmuxClients() throws {
        try writeSession(pid: getpid(), SessionsFixtures.background, status: "idle", extra: #","tmux":"ca-ca-view-mac-1:@0.%0""#)
        let clients: [(pid: Int32, session: String)] = [(71001, "ca-ca-view-mac-1"), (71002, "ca-ca-view-mac-1"),
                                                        (71003, "ca-ca-view-mac-1"), (71004, "other"), (71005, "ca-ca-view-mac-1")]
        let r = try XCTUnwrap(scanner(clients: clients).running().first)
        XCTAssertEqual(r.clients?.count, 4, "only this session's clients")
        let s = ClaudeSession.make(hostId: "mac", raw: r)
        XCTAssertEqual(s.viewers, [.ghostty, .terminal, .other], "CrossAgent's own client left out, unknown pid is other")
        XCTAssertEqual(SessionLauncher.alsoOpen(s.viewers), "Also open in Ghostty, Terminal and a terminal")
    }

    func testNoClientsNoViewers() throws {
        try writeSession(pid: getpid(), SessionsFixtures.background, status: "idle", extra: #","tmux":"ca-ca-view-mac-1:@0.%0""#)
        let r = try XCTUnwrap(scanner(clients: [(71003, "ca-ca-view-mac-1")]).running().first)
        XCTAssertEqual(ClaudeSession.make(hostId: "mac", raw: r).viewers, [])
        // Not in tmux: clients are never looked up.
        try writeSession(pid: getpid(), SessionsFixtures.background, status: "idle")
        XCTAssertNil(try XCTUnwrap(scanner(clients: [(71001, "x")]).running().first).clients)
    }

    func testViewerClassification() {
        let v = LauncherClassifier.viewers([
            RawClient(chain: ["bash", "sshd-session", "sshd"], ca: true),          // CrossAgent over ssh
            RawClient(chain: ["bash", "sshd-session", "sshd"], ca: false),         // someone's ssh login
            RawClient(chain: ["zsh", "sshd: pc@pts/3", "sshd"]),
            RawClient(chain: ["-zsh", "login", "/Applications/Ghostty.app/Contents/MacOS/ghostty"]),
        ])
        XCTAssertEqual(v, [.ssh, .ghostty])
        XCTAssertNil(SessionLauncher.alsoOpen([]))
        XCTAssertEqual(SessionLauncher.alsoOpen([.ghostty]), "Also open in Ghostty")
        XCTAssertEqual(SessionLauncher.alsoOpen([.ghostty, .ssh]), "Also open in Ghostty and ssh")
    }

    func testParseClients() {
        let out = "123\tca-x-mac-1\t/dev/ttys004\nbad line\n456\tmy session\t/dev/pts/2\n"
        let c = LocalSessionScanner.parseClients(out)
        XCTAssertEqual(c.map(\.pid), [123, 456])
        XCTAssertEqual(c.map(\.session), ["ca-x-mac-1", "my session"])
    }

    func testRemoteScanDecodesClients() throws {
        let json = #"{"running":[{"sid":"a","path":"/p","pid":5,"tmux":"t","clients":[{"chain":["bash","sshd"],"ca":true},{"chain":["bash","sshd"],"ca":false}]}]}"#
        let scan = try JSONDecoder().decode(RemoteScan.self, from: Data(json.utf8))
        XCTAssertEqual(ClaudeSession.make(hostId: "pc", raw: scan.running[0]).viewers, [.ssh])
    }

    /// Both hosts through `SessionDiscovery`; the "PC" runs the real discovery script
    /// with local python against the same fake root (no /proc here, so nothing runs there).
    func testDiscoveryBothHosts() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.python) else { throw XCTSkip("no python3") }
        try writeSession(pid: getpid(), SessionsFixtures.background, status: "busy")
        let defaults = UserDefaults(suiteName: "ca-sessions-test-\(UUID().uuidString)")!
        var calls: [[String]] = []
        let d = SessionDiscovery(hosts: [mac, pc], localRoot: root.path, remoteRoot: root.path, defaults: defaults,
                                 scanner: scanner()) { _, argv in
            calls.append(argv)
            return SpawnCommand(executable: Self.python, args: ["-I", "-c", SessionScripts.discovery] + argv)
        }
        XCTAssertEqual(d.recentDays, 7)
        await d.refresh()
        XCTAssertNil(d.hostErrors["pc"])
        let macs = d.sessions.filter { $0.hostId == "mac" }
        let pcs = d.sessions.filter { $0.hostId == "pc" }
        XCTAssertEqual(macs.count, 3)
        XCTAssertEqual(pcs.count, 3)
        XCTAssertEqual(d.sessions.first?.id, "mac:\(SessionsFixtures.background.sessionId)", "running first")
        XCTAssertTrue(d.isRunning(host: "mac", sessionId: SessionsFixtures.background.sessionId))
        XCTAssertFalse(d.isRunning(host: "pc", sessionId: SessionsFixtures.background.sessionId))
        let pcTeam = try XCTUnwrap(pcs.first { $0.sessionId == SessionsFixtures.teammate.sessionId })
        XCTAssertEqual(pcTeam.title, "Touch made.txt in /tmp probe")
        XCTAssertEqual(pcTeam.subagentCount, 1)
        XCTAssertEqual(pcTeam.cwd, "/private/tmp/ca-sess-probe2")
        XCTAssertEqual(pcs.first { $0.sessionId == SessionsFixtures.foreground.sessionId }?.subagentCount, 2)

        // Second round: heads are known, the script skips them, titles stay.
        await d.refresh()
        let known = try JSONSerialization.jsonObject(with: Data(calls.last![3].utf8)) as? [String: Int]
        XCTAssertEqual(known?.count, 3)
        XCTAssertEqual(d.sessions.first { $0.hostId == "pc" && $0.sessionId == SessionsFixtures.teammate.sessionId }?.title,
                       "Touch made.txt in /tmp probe")

        // The running one stops: it shows as ended at once.
        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/\(getpid()).json"))
        await d.refresh()
        XCTAssertFalse(d.isRunning(host: "mac", sessionId: SessionsFixtures.background.sessionId))
        XCTAssertEqual(d.sessions.filter { $0.hostId == "mac" }.count, 3)
        d.recentDays = 3
        XCTAssertEqual(defaults.integer(forKey: SessionDiscovery.recentDaysKey), 3)
    }

    func testRemoteFailureIsReported() async {
        let d = SessionDiscovery(hosts: [pc], localRoot: root.path, defaults: UserDefaults(suiteName: "ca-t-\(UUID())")!) { _, _ in
            SpawnCommand(executable: "/bin/sh", args: ["-c", "echo 'ssh: connect to host pc: Connection refused' >&2; exit 255"])
        }
        await d.refresh()
        XCTAssertEqual(d.hostErrors["pc"], "ssh: connect to host pc: Connection refused")
        XCTAssertTrue(d.sessions.isEmpty)
    }

    func testRemoteCommandShape() {
        let c = SessionDiscovery.remoteCommand(host: pc, argv: ["~/.claude", "1", "7", "{}"])
        XCTAssertEqual(c.executable, "/usr/bin/ssh")
        XCTAssertTrue(c.args.contains("ControlMaster=auto"))
        XCTAssertTrue(c.args.last?.contains("python3 -I -c") ?? false)
    }
}
