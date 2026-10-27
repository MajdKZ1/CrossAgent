@testable import CrossAgent
import XCTest

/// Live checks against this Mac and the PC. Skipped unless CA_LIVE_EVENTS_DIR points at
/// a throwaway project folder (with a matching folder under the PC's $HOME named by
/// CA_LIVE_EVENTS_PC_DIR, optional).
///   CA_LIVE_EVENTS_STEP=install  installs the hook script on every host and our hooks
///   CA_LIVE_EVENTS_STEP=follow   follows both hosts, writes a line on the PC, removes hooks
final class EventsLiveTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private var scriptData: Data {
        get throws {
            try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/CrossAgent/Resources/crossagent-hook.py"))
        }
    }

    private func setup(_ step: String) throws -> (dir: String, pcDir: String) {
        guard let dir = env["CA_LIVE_EVENTS_DIR"], env["CA_LIVE_EVENTS_STEP"] == step else { throw XCTSkip() }
        return (dir, env["CA_LIVE_EVENTS_PC_DIR"] ?? "")
    }

    func testLiveInstall() async throws {
        let (dir, pcDir) = try setup("install")
        let body = try scriptData
        for h in HostStore.defaults {
            let ok = await HookInstaller.installHookScript(on: h, script: body)
            XCTAssertTrue(ok, "script on \(h.id)")
            if !h.isLocal, !pcDir.isEmpty {
                let ok = await HookInstaller.installHooks(on: h, relativePath: pcDir)
                XCTAssertTrue(ok, "hooks on \(h.id)")
            }
        }
        try HookInstaller.installHooks(projectPath: dir)
        XCTAssertTrue(HookInstaller.hooksInstalled(projectPath: dir))
    }

    @MainActor
    func testLiveFollowAndRemove() async throws {
        let (dir, pcDir) = try setup("follow")
        let graph = AgentGraph()
        var got: [String: [AgentEvent]] = [:]
        let followers = HostStore.defaults.map { h in
            EventFollower(host: h, replay: 600) { events in
                got[h.id, default: []] += events
                graph.apply(events, project: "e2e", projectPaths: ["mac": dir, "pc": pcDir])
            }
        }
        for f in followers { f.start() }
        defer { for f in followers { f.stop() } }

        // Replayed history from the claude -p run on the Mac.
        try await waitFor(20) { (got["mac"] ?? []).contains { $0.ev == "SessionEnd" && $0.project == "e2e" } }
        print("LIVE mac events:", got["mac"]?.count ?? 0)
        print("LIVE graph:", graph.nodes.values.map { "\($0.name)=\($0.state)" }.sorted())

        // A fresh line written on the PC shows up over ssh.
        let pc = HostStore.defaults.first { !$0.isLocal }!
        let mark = "live-\(UUID().uuidString.prefix(8))"
        let line = #"{"ts":\#(Date().timeIntervalSince1970),"ev":"WorkerStart","host":"pc","sid":"ca-e2e-pc-\#(mark)","tmux":"ca-e2e-pc-\#(mark)","role":"worker","project":"e2e","node":"\#(mark)","sum":"live check"}"#
        try await Task.sleep(nanoseconds: 3_000_000_000)  // let the ssh follower settle at the end of files
        let sent = Date()
        let w = await EventShell.run(CommandBuilder.oneShot(host: pc, script: "cat >> ~/.crossagent/events/ca-e2e-pc-\(mark).jsonl"),
                                     input: Data((line + "\n").utf8))
        XCTAssertEqual(w.status, 0)
        try await waitFor(15) { (got["pc"] ?? []).contains { $0.node == mark } }
        print("LIVE pc line latency:", String(format: "%.2f s", Date().timeIntervalSince(sent)))
        XCTAssertEqual(graph.nodes["ca-e2e-pc-\(mark)"]?.state, .working)
        XCTAssertEqual(graph.nodes["ca-e2e-pc-\(mark)"]?.hostId, "pc")

        try HookInstaller.removeHooks(projectPath: dir)
        XCTAssertFalse(HookInstaller.hooksInstalled(projectPath: dir))
        if !pcDir.isEmpty {
            let ok = await HookInstaller.removeHooks(on: pc, relativePath: pcDir)
            XCTAssertTrue(ok)
        }
        _ = await EventShell.run(CommandBuilder.oneShot(host: pc, script: "rm -f ~/.crossagent/events/ca-e2e-pc-\(mark).jsonl"))
    }

    @MainActor
    private func waitFor(_ seconds: Double, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() > end { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
