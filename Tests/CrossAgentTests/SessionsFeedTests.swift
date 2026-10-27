import XCTest
@testable import CrossAgent

@MainActor
final class SessionsFeedTests: XCTestCase {
    private var root: URL!
    private let mac = Host(id: "mac", name: "This Mac", type: .local, target: nil, accent: "#6ea8fe")

    override func setUp() async throws {
        root = try SessionsFixtures.makeRoot()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func wait(_ timeout: TimeInterval = 4, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func append(_ s: String, to url: URL) throws {
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(s.utf8))
        try fh.close()
    }

    func testLocalFeedTailsIncrementally() async throws {
        let bg = SessionsFixtures.background
        let expected = SessionsFixtures.items(bg).count
        let feed = SessionFeed(host: mac, sessionId: bg.sessionId, localRoot: root.path)
        feed.retain()
        defer { feed.shutdown() }
        await wait { feed.items.count >= expected && feed.status == .ended }
        XCTAssertEqual(feed.items.count, expected)
        XCTAssertEqual(feed.status, .ended, "no session file")
        XCTAssertEqual(feed.graph.others.map(\.name), ["reader", "lister"])
        XCTAssertTrue(feed.graph.others.allSatisfy { $0.state == .done })

        // A half written line waits for its newline, then shows once.
        let main = root.appendingPathComponent("projects/-private-tmp-ca-sess-probe/\(bg.sessionId).jsonl")
        let line = #"{"type":"assistant","uuid":"new-1","timestamp":"2026-10-27T15:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"later"}]}}"#
        try append(String(line.prefix(40)), to: main)
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(feed.items.count, expected)
        try append(String(line.dropFirst(40)) + "\n", to: main)
        await wait { feed.items.count > expected }
        XCTAssertEqual(feed.items.last?.text, "later")
        XCTAssertEqual(feed.items.count, expected + 1)

        // A live session file flips the status.
        let sf = #"{"pid":\#(getpid()),"sessionId":"\#(bg.sessionId)","cwd":"\#(bg.cwd)","status":"waiting","waitingFor":"input needed"}"#
        try Data(sf.utf8).write(to: root.appendingPathComponent("sessions/\(getpid()).json"))
        await wait { feed.status == .waiting }
        XCTAssertEqual(feed.status, .waiting)
        XCTAssertEqual(feed.graph.orchestrator?.state, .needsInput("Needs your input"))

        // A new subagent appears mid session.
        let subs = root.appendingPathComponent("projects/-private-tmp-ca-sess-probe/\(bg.sessionId)/subagents")
        try Data(#"{"agentType":"general-purpose","name":"late","toolUseId":"toolu_late","finished":false}"#.utf8)
            .write(to: subs.appendingPathComponent("agent-alate.meta.json"))
        try Data((#"{"type":"assistant","isSidechain":true,"agentId":"alate","uuid":"late-1","timestamp":"2026-10-27T15:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q","name":"Bash","input":{"command":"make"}}]}}"# + "\n").utf8)
            .write(to: subs.appendingPathComponent("agent-alate.jsonl"))
        await wait { feed.graph.nodes["toolu_late"]?.state == .working }
        XCTAssertEqual(feed.graph.nodes["toolu_late"]?.name, "late")
        XCTAssertEqual(feed.graph.nodes["toolu_late"]?.recent, ["Running make"])
    }

    /// The PC follower script, run with local python against the fake root.
    func testRemoteFollowerScript() async throws {
        guard FileManager.default.isExecutableFile(atPath: SessionsDiscoveryTests.python) else { throw XCTSkip("no python3") }
        let tm = SessionsFixtures.teammate
        let cmd = SpawnCommand(executable: SessionsDiscoveryTests.python,
                               args: ["-I", "-u", "-c", SessionScripts.follower, root.path, tm.sessionId, "16777216"])
        let feed = SessionFeed(host: mac, sessionId: tm.sessionId) { feed in
            RemoteTranscriptFollower(host: Host(id: "pc", name: "", type: .ssh, target: "pc", accent: ""), sessionId: tm.sessionId,
                                     command: cmd) { [weak feed] b in feed?.apply(b) }
        }
        feed.retain()
        defer { feed.shutdown() }
        let expected = SessionsFixtures.items(tm).count
        await wait(6) { feed.items.count >= expected && feed.status == .ended }
        XCTAssertEqual(feed.items.count, expected)
        XCTAssertEqual(feed.status, .ended)
        XCTAssertEqual(feed.graph.others.first?.name, "sleeper")
        XCTAssertEqual(feed.graph.others.first?.state, .done)
        feed.shutdown()
        XCTAssertEqual(ActivityTests.processes(matching: root.path, ownChildren: true), "", "shutdown waits for the follower")
    }

    /// When ssh goes away the follower notices on its next heartbeat and exits.
    func testFollowerExitsWhenPipeCloses() async throws {
        guard FileManager.default.isExecutableFile(atPath: SessionsDiscoveryTests.python) else { throw XCTSkip("no python3") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SessionsDiscoveryTests.python)
        p.arguments = ["-I", "-u", "-c", SessionScripts.follower, root.path, "no-such-session", "1024"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        try await Task.sleep(nanoseconds: 700_000_000)
        try out.fileHandleForReading.close()
        let end = Date().addingTimeInterval(5)
        while p.isRunning, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(p.isRunning)
        if p.isRunning { p.terminate() }
    }

    func testSharedFeedPerSession() {
        let a = SessionFeed.feed(host: "mac", sessionId: "shared-test")
        let b = SessionFeed.feed(host: "mac", sessionId: "shared-test")
        XCTAssertTrue(a === b)
        XCTAssertFalse(a === SessionFeed.feed(host: "pc", sessionId: "shared-test"))
    }
}

final class SessionsFeedLifecycleTests: XCTestCase {
    /// Same regression as EventFollowerLifecycleTests: a stdout handler left on a pipe at
    /// EOF fires nonstop. Twenty start/stop rounds must leave CPU flat and no process.
    @MainActor
    func testStartStopLeaksNoHandlerOrProcess() async throws {
        let marker = "ca-session-follower-test-\(UUID().uuidString.prefix(8))"
        let script = #"trap 'exit 0' TERM; i=0; while :; do i=$((i+1)); printf 'hb\t{}\n'; sleep 0.05; done"#
        let fake = SpawnCommand(executable: "/bin/sh", args: ["-c", script, marker])
        let pc = Host(id: "pc", name: "Linux PC", type: .ssh, target: "pc", accent: "#5fd39a")
        let follower = RemoteTranscriptFollower(host: pc, sessionId: "x", command: fake) { _ in }
        for _ in 0..<20 {
            follower.start()
            try await Task.sleep(nanoseconds: 150_000_000)
            follower.stop()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        follower.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        follower.shutdown()
        XCTAssertEqual(ActivityTests.processes(matching: marker), "", "shutdown waits for the process")

        // A source that dies on its own (EOF first, then exit) must not spin either.
        let dying = RemoteTranscriptFollower(host: pc, sessionId: "x",
                                             command: SpawnCommand(executable: "/bin/sh", args: ["-c", "printf 'hb\\t{}\\n'; exit 0", marker])) { _ in }
        dying.start()
        try await Task.sleep(nanoseconds: 500_000_000)

        let before = ActivityTests.cpuSeconds()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let used = ActivityTests.cpuSeconds() - before
        dying.shutdown()
        XCTAssertLessThan(used, 0.2, "CPU while stopped should be flat, got \(used) s over 2 s")
        XCTAssertEqual(ActivityTests.processes(matching: marker), "")
    }

    @MainActor
    func testLocalTailerIdleCostsLittle() async throws {
        let root = try SessionsFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tailer = LocalTranscriptTailer(root: root.path, sessionId: SessionsFixtures.background.sessionId) { _ in }
        tailer.start()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let before = ActivityTests.cpuSeconds()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let used = ActivityTests.cpuSeconds() - before
        tailer.shutdown()
        XCTAssertLessThan(used, 0.15, "an idle tail should be a few stats a second, got \(used) s over 3 s")
    }
}
