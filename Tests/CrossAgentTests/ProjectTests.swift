import XCTest
@testable import CrossAgent

final class ProjectTests: XCTestCase {
    let home = "/Users/me"
    let mac = HostStore.example[0]
    let pc = HostStore.example[1]

    func testUnderHomeKeepsRelativePath() {
        let p = Project(path: "/Users/me/Projects/My App/", home: home, config: nil)
        XCTAssertEqual(p.path, "/Users/me/Projects/My App")
        XCTAssertEqual(p.name, "My App")
        XCTAssertEqual(p.slug, "my-app")
        XCTAssertEqual(p.pcRelativePath, "Projects/My App")
        XCTAssertEqual(p.id, p.path)
    }

    func testOutsideHomeGoesUnderCrossagentProjects() {
        let p = Project(path: "/Volumes/Work/my app+1", home: home, config: nil)
        XCTAssertEqual(p.pcRelativePath, "crossagent/projects/my_app_1")
        // Home itself is not "under" home, same as the ca script's "$HOME"/* pattern.
        XCTAssertEqual(Project(path: "/Users/me", home: home, config: nil).pcRelativePath, "crossagent/projects/me")
        // A sibling with home as a string prefix is outside home.
        XCTAssertEqual(Project(path: "/Users/meow/x", home: home, config: nil).pcRelativePath, "crossagent/projects/x")
    }

    func testPcDirOverrideWins() {
        let conf = "name=x\n# pc_dir=commented/out\npc_dir=crossagent/projects/x\npc_dir=second\n"
        let p = Project(path: "/Users/me/Projects/x", home: home, config: conf)
        XCTAssertEqual(p.pcRelativePath, "crossagent/projects/x")
        // Empty pc_dir= falls back like the script.
        XCTAssertEqual(Project(path: "/Users/me/a", home: home, config: "pc_dir=\n").pcRelativePath, "a")
    }

    func testSafeName() {
        XCTAssertEqual(Project.safeName("my.app_v2-x"), "my.app_v2-x")
        XCTAssertEqual(Project.safeName("a b&c"), "a_b_c")
    }

    func testSyncSessionName() {
        XCTAssertEqual(Project.syncSessionName(name: "CrossAgent"), "ca-CrossAgent")
        XCTAssertEqual(Project.syncSessionName(name: "my app.v2"), "ca-my-app-v2")
        XCTAssertEqual(Project.syncSessionName(name: "_a__b_"), "ca-a-b")
        XCTAssertEqual(Project.syncSessionName(name: "--x--"), "ca-x")
    }

    /// Checks pc_dir and sess against the real ca script when it is in the repo.
    func testMatchesCaScript() throws {
        let ca = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("skills/crossagent/scripts/ca")
        guard FileManager.default.fileExists(atPath: ca.path) else { throw XCTSkip("no ca script") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ca test \(UUID().uuidString.prefix(6))/my app.v2+x")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        // Source the script's functions only: everything before the dispatch at the bottom.
        let script = """
        src="$(sed -n '1,/^# ---------- hosts/p' \(CommandBuilder.shellQuote(ca.path)))"
        eval "$src"; set_root \(CommandBuilder.shellQuote(tmp.path))
        eval "$(grep '^sess()' \(CommandBuilder.shellQuote(ca.path)))"
        pc_dir; sess
        """
        let r = Runner.runSync(SpawnCommand(executable: "/bin/bash", args: ["-c", script]))
        let lines = r.stdout.split(separator: "\n").map(String.init)
        let p = Project(url: tmp)
        XCTAssertEqual(lines, [p.pcRelativePath, p.syncSessionName], r.stderr)
    }

    func testCwd() {
        let p = Project(path: "/Users/me/Projects/x", home: home, config: nil)
        XCTAssertEqual(p.cwd(for: mac), "/Users/me/Projects/x")
        XCTAssertEqual(p.cwd(for: pc), "$HOME/Projects/x")
    }

    // MARK: State

    func testStateRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let node = AgentNode(id: "w1", name: "tests", kind: .worker, hostId: "pc", state: .done,
                             activity: "Done", tmuxSession: "ca-x-pc-tests", startedAt: now, updatedAt: now)
        let s = ProjectState(panes: [SavedPane(hostId: "pc", mode: .claude, session: "ca-x-pc-1")],
                             mode: "orchestrator",
                             orchestrator: OrchestratorState(hostId: "mac", session: "ca-x-mac-orch", enabled: true),
                             nodePositions: ["w1": CGPoint(x: 10, y: -4.5)], finishedNodes: [node])
        let back = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testLenientDecode() throws {
        let empty = try JSONDecoder().decode(ProjectState.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, ProjectState())
        let partial = try JSONDecoder().decode(ProjectState.self, from: Data(#"""
        {"panes":[{"hostId":"mac","mode":"shell","session":"ca-x-mac-1"}],"mode":"station",
         "orchestrator":{"hostId":"pc"},"nodePositions":"junk","extra":1}
        """#.utf8))
        XCTAssertEqual(partial.panes.count, 1)
        XCTAssertEqual(partial.mode, "station")
        XCTAssertNil(partial.orchestrator)
        XCTAssertEqual(partial.nodePositions, [:])
        XCTAssertNil(partial.finishedNodes)
    }

    func testStoreRecentsAndState() throws {
        let suite = "crossagent.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ca-store-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(defaults: defaults, stateDir: root.appendingPathComponent("state"))

        var projects: [Project] = []
        for i in 0..<12 {
            let dir = root.appendingPathComponent("p\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = Project(url: dir)
            projects.append(p)
            store.noteOpened(p, at: Date(timeIntervalSince1970: Double(1000 + i)))
        }
        // Reopening moves it to the front without a duplicate.
        store.noteOpened(projects[5], at: Date(timeIntervalSince1970: 5000))
        var names = store.recents().map(\.name)
        XCTAssertEqual(names.count, 10)
        XCTAssertEqual(names.first, "p5")
        XCTAssertEqual(names[1], "p11")
        // Deleted folders drop out.
        try FileManager.default.removeItem(at: projects[11].url)
        names = store.recents().map(\.name)
        XCTAssertFalse(names.contains("p11"))
        XCTAssertEqual(names.count, 9)

        store.lastProjectPath = projects[0].path
        XCTAssertEqual(store.lastProjectPath, projects[0].path)
        store.lastProjectPath = nil
        XCTAssertNil(store.lastProjectPath)

        let url = store.stateURL(for: projects[0])
        XCTAssertTrue(url.lastPathComponent.hasPrefix("p0-"))
        XCTAssertEqual(url.lastPathComponent.count, "p0-".count + 8 + ".json".count)
        XCTAssertEqual(store.loadState(for: projects[0]), ProjectState())
        let s = ProjectState(panes: [SavedPane(hostId: "mac", mode: .shell, session: "ca-p0-mac-1")], mode: "panes")
        store.saveState(s, for: projects[0])
        XCTAssertEqual(store.loadState(for: projects[0]), s)
        XCTAssertEqual(store.loadState(for: projects[1]), ProjectState())
    }

    // MARK: integration (CA_INTEGRATION=1 swift test --filter ProjectTests/testLiveProjectCwd)

    /// Spawns a shell pane for a throwaway project on every host through a real PTY and
    /// checks tmux started it in the project folder with CROSSAGENT_PROJECT set. Also
    /// checks an attach-only pane never creates a missing session. Cleans up after itself.
    func testLiveProjectCwd() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CA_INTEGRATION"] == "1")
        let project = Project(url: URL(fileURLWithPath: NSHomeDirectory() + "/Projects/ca-core-check"))
        for host in HostStore.example {
            let dir = CommandBuilder.shellPath(project.cwd(for: host))
            let session = CASessionName.make(slug: project.slug, host: host.id, task: "check")
            func sh(_ script: String) async -> Runner.Result {
                await Runner.run(CommandBuilder.oneShot(host: host, script: script), timeout: 40)
            }
            let made = await sh("mkdir -p \(dir)").status
            XCTAssertEqual(made, 0)
            let cmd = CommandBuilder.command(host: host, mode: .shell, session: session, cwd: project.cwd(for: host),
                                             env: ["CROSSAGENT_PROJECT": project.slug])
            let client = Process()
            client.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            // Same TERM the app gives panes; the PC may not know the test runner's.
            client.arguments = ["-q", "/dev/null", "/usr/bin/env", "TERM=xterm-256color", cmd.executable] + cmd.args
            client.standardInput = Pipe()
            client.standardOutput = FileHandle.nullDevice
            try client.run()
            var path = ""
            for _ in 0..<40 {
                let r = await sh("tmux display -p -t '=\(session):' '#{pane_current_path}' 2>/dev/null")
                path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            let env = await sh("tmux show-environment -t '=\(session)' CROSSAGENT_PROJECT").stdout
            let home = await sh("cd && pwd -P").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[\(host.id)] \(session) cwd=\(path) env=\(env.trimmingCharacters(in: .whitespacesAndNewlines))")
            XCTAssertEqual(path, home + "/" + project.pcRelativePath)
            XCTAssertEqual(env.trimmingCharacters(in: .whitespacesAndNewlines), "CROSSAGENT_PROJECT=\(project.slug)")

            // Attach only, to a session that does not exist: must exit and create nothing.
            let ghost = CASessionName.make(slug: project.slug, host: host.id, task: "ghost")
            let a = CommandBuilder.command(host: host, mode: .shell, session: ghost, attachOnly: true)
            let r = await Runner.run(SpawnCommand(executable: "/usr/bin/script", args: ["-q", "/dev/null", "/usr/bin/env", "TERM=xterm-256color", a.executable] + a.args), timeout: 40)
            XCTAssertNotEqual(r.status, 0)
            let ghostExists = await sh("tmux has-session -t '=\(ghost)' 2>/dev/null").status
            XCTAssertNotEqual(ghostExists, 0)

            _ = await Runner.run(CommandBuilder.killCommand(host: host, session: session))
            client.terminate()
            let left = await sh("rm -rf \(dir) && rmdir \"$HOME\"/Projects 2>/dev/null; tmux has-session -t '=\(session)' 2>/dev/null").status
            XCTAssertEqual(left, 1)
        }
    }
}
