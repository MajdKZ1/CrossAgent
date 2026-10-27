@testable import CrossAgent
import XCTest

/// Nasty folder names, link tricks and loose modes against the hook installer and the
/// event files. Shell lines run for real in sh, bash and zsh with HOME on a temp folder.
final class HookInstallerQuotingTests: XCTestCase {
    static let nasty = [
        #"my "proj" $(touch PWNED) 'x'"#,
        "-rf",
        "--",
        "`touch PWNED`",
        "a\nb; touch PWNED",
        "sp ace/ünï cødé ✓",
        "$HOME",
        "~",
        "*",
    ]

    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ca-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func shells() -> [String] {
        ["/bin/sh", "/bin/bash", "/bin/zsh"].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `script` in `shell` with HOME (and the working folder) set to `home`.
    @discardableResult
    private func run(_ shell: String, _ script: String, home: URL, input: Data = Data()) throws -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", script]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        p.currentDirectoryURL = home
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        try inp.fileHandleForWriting.write(contentsOf: input)
        try inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    private func mode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }

    func testRemoteScriptsQuoteThePath() {
        let s = HookInstaller.remoteScripts(relativePath: #"my "proj" $(touch PWNED) 'x'"#)
        let dir = #""$HOME"/'my "proj" $(touch PWNED) '\''x'\'''/.claude"#
        XCTAssertEqual(s.read, "cat \(dir)/settings.local.json 2>/dev/null || true")
        XCTAssertEqual(s.write, "mkdir -p \(dir) && rm -f \(dir)/settings.local.json.ca-tmp && cat > \(dir)/settings.local.json.ca-tmp"
            + " && mv -f \(dir)/settings.local.json.ca-tmp \(dir)/settings.local.json")
        XCTAssertEqual(s.delete, "rm -f \(dir)/settings.local.json")

        XCTAssertEqual(HookInstaller.remoteScripts(relativePath: "-rf").delete, #"rm -f "$HOME"/'-rf'/.claude/settings.local.json"#,
                       "a leading dash never starts a word")
        XCTAssertEqual(HookInstaller.remoteScripts(relativePath: "").delete, #"rm -f "$HOME"/.claude/settings.local.json"#)
        XCTAssertEqual(HookInstaller.remoteScripts(relativePath: "/abs/p").delete, #"rm -f "$HOME"/'abs/p'/.claude/settings.local.json"#,
                       "always under $HOME, like the panes' cwd")
        XCTAssertEqual(HookInstaller.remoteScripts(relativePath: "a\nb").read, "cat \"$HOME\"/'a\nb'/.claude/settings.local.json 2>/dev/null || true")
    }

    func testRemoteScriptsRoundTripInEveryShell() throws {
        for shell in shells() {
            for name in Self.nasty {
                let home = try tempHome()
                defer { try? FileManager.default.removeItem(at: home) }
                let project = home.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let s = HookInstaller.remoteScripts(relativePath: name)
                let what = "\(shell) \(name.debugDescription)"

                let (rc0, none) = try run(shell, s.read, home: home)
                XCTAssertEqual(rc0, 0, what)
                XCTAssertTrue(none.isEmpty, what)

                let body = HookInstaller.install(into: nil)
                XCTAssertEqual(try run(shell, s.write, home: home, input: body).0, 0, what)
                let file = project.appendingPathComponent(".claude/settings.local.json")
                XCTAssertEqual(try? Data(contentsOf: file), body, what)
                XCTAssertEqual(try run(shell, s.read, home: home).1, body, what)

                XCTAssertEqual(try run(shell, s.delete, home: home).0, 0, what)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), what)

                let left = try FileManager.default.subpathsOfDirectory(atPath: home.path)
                XCTAssertFalse(left.contains { ($0 as NSString).lastPathComponent == "PWNED" }, "\(what) ran something: \(left)")
                let top = String(name.split(separator: "/").first!)
                XCTAssertEqual(left.filter { !$0.hasPrefix(top) }, [], "\(what) wrote outside the project: \(left)")
            }
        }
    }

    func testLocalRoundTripOnANastyFolder() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for name in Self.nasty {
            let dir = home.appendingPathComponent(name)
            try HookInstaller.installHooks(projectPath: dir.path)
            XCTAssertTrue(HookInstaller.hooksInstalled(projectPath: dir.path), name)
            try HookInstaller.removeHooks(projectPath: dir.path)
            XCTAssertFalse(HookInstaller.hooksInstalled(projectPath: dir.path), name)
        }
        let left = try FileManager.default.subpathsOfDirectory(atPath: home.path)
        XCTAssertFalse(left.contains { ($0 as NSString).lastPathComponent == "PWNED" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/PWNED"))
    }

    // MARK: Hook script install

    func testRemoteScriptInstall() throws {
        let body = Data("print('hi')\n".utf8)
        for shell in shells() {
            let home = try tempHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let bin = home.appendingPathComponent(".crossagent/bin")
            let file = bin.appendingPathComponent("crossagent-hook.py")

            XCTAssertEqual(try run(shell, HookInstaller.remoteScriptInstall, home: home, input: body).0, 0, shell)
            XCTAssertEqual(try Data(contentsOf: file), body, shell)
            XCTAssertEqual(mode(bin.path), 0o700, shell)
            XCTAssertEqual(mode(file.path), 0o600, shell)

            // A loose folder is tightened, a link where the script goes is replaced, not followed.
            chmod(bin.path, 0o775)
            let victim = home.appendingPathComponent("victim")
            try Data("keep".utf8).write(to: victim)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim)
            XCTAssertEqual(try run(shell, HookInstaller.remoteScriptInstall, home: home, input: body).0, 0, shell)
            XCTAssertEqual(try Data(contentsOf: victim), Data("keep".utf8), shell)
            XCTAssertEqual(try Data(contentsOf: file), body, shell)
            XCTAssertEqual(mode(bin.path), 0o700, shell)

            // A linked bin folder is refused.
            let elsewhere = home.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: bin)
            try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: elsewhere)
            XCTAssertNotEqual(try run(shell, HookInstaller.remoteScriptInstall, home: home, input: body).0, 0, shell)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], shell)
        }
    }

    func testLocalScriptInstall() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let body = Data("print('hi')\n".utf8)
        let bin = home.appendingPathComponent(".crossagent/bin")
        let file = bin.appendingPathComponent("crossagent-hook.py")

        XCTAssertTrue(HookInstaller.installHookScript(body, home: home))
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(mode(bin.path), 0o700)
        XCTAssertEqual(mode(file.path), 0o600)

        chmod(file.path, 0o755)
        chmod(bin.path, 0o777)
        XCTAssertTrue(HookInstaller.installHookScript(body, home: home), "same body, modes still fixed")
        XCTAssertEqual(mode(bin.path), 0o700)
        XCTAssertEqual(mode(file.path), 0o600)

        let victim = home.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim)
        XCTAssertTrue(HookInstaller.installHookScript(body, home: home))
        XCTAssertEqual(try Data(contentsOf: victim), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: file), body)

        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: bin)
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: elsewhere)
        XCTAssertFalse(HookInstaller.installHookScript(body, home: home))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }
}

/// The hook and its follower refuse event files and folders they can't trust.
final class HookScriptTrustTests: XCTestCase {
    private var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CrossAgent/Resources/crossagent-hook.py")
    }

    private func python() throws -> String {
        for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        throw XCTSkip("no python3")
    }

    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ca-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func run(_ args: [String], home: URL, env: [String: String] = [:], input: Data = Data(),
                     stopAfter: TimeInterval? = nil) throws -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try python())
        // -B: running the repo's hook must not leave __pycache__ in Sources (SwiftPM warns about it).
        p.arguments = ["-I", "-B"] + args
        p.environment = ["HOME": home.path].merging(env) { $1 }
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        try inp.fileHandleForWriting.write(contentsOf: input)
        try inp.fileHandleForWriting.close()
        if let stopAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + stopAfter) { if p.isRunning { p.terminate() } }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    private func hook(_ sid: String, home: URL) throws {
        let payload = #"{"hook_event_name":"SessionStart","session_id":"\#(sid)","cwd":"/tmp"}"#
        let (rc, out) = try run([script.path], home: home, env: ["CROSSAGENT_HOST": "mac"], input: Data(payload.utf8))
        XCTAssertEqual(rc, 0)
        XCTAssertTrue(out.isEmpty)
    }

    private func mode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }

    func testHookNeverWritesThroughALink() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let events = home.appendingPathComponent(".crossagent/events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        let victim = home.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: events.appendingPathComponent("s1.jsonl"), withDestinationURL: victim)
        try hook("s1", home: home)
        XCTAssertEqual(try Data(contentsOf: victim), Data("keep".utf8))

        // A group writable file is not ours to trust either.
        let loose = events.appendingPathComponent("s2.jsonl")
        try Data().write(to: loose)
        chmod(loose.path, 0o666)
        try hook("s2", home: home)
        XCTAssertEqual(try Data(contentsOf: loose), Data())

        // The folder was made by hand with a loose mode: tightened, then used.
        chmod(events.path, 0o755)
        try hook("s3", home: home)
        XCTAssertEqual(mode(events.path), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: events.appendingPathComponent("s3.jsonl").path))
    }

    func testHookRefusesALinkedEventsFolder() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".crossagent"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".crossagent/events"), withDestinationURL: elsewhere)
        try hook("s1", home: home)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])

        let (rc, out) = try run([script.path, "--follow", "~/.crossagent/events"], home: home, stopAfter: 5)
        XCTAssertEqual(rc, 3, "the follower refuses a linked folder")
        XCTAssertTrue(out.isEmpty)
    }

    func testFollowerSkipsFilesItCannotTrust() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let events = home.appendingPathComponent(".crossagent/events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        chmod(events.path, 0o755)
        let line = { (sid: String) in Data(#"{"ts":\#(Date().timeIntervalSince1970),"ev":"Stop","sid":"\#(sid)"}"#.utf8 + [0x0A]) }

        try line("good").write(to: events.appendingPathComponent("good.jsonl"))
        chmod(events.appendingPathComponent("good.jsonl").path, 0o600)
        try line("loose").write(to: events.appendingPathComponent("loose.jsonl"))
        chmod(events.appendingPathComponent("loose.jsonl").path, 0o620)
        let outside = home.appendingPathComponent("outside.jsonl")
        try line("linked").write(to: outside)
        chmod(outside.path, 0o600)
        try FileManager.default.createSymbolicLink(at: events.appendingPathComponent("linked.jsonl"), withDestinationURL: outside)

        let (_, out) = try run([script.path, "--follow", "~/.crossagent/events", "--since", "0"], home: home, stopAfter: 2.5)
        let sids = String(decoding: out, as: UTF8.self).split(separator: "\n")
            .compactMap { EventFollower.parse(Data($0.utf8))?.sid }
        XCTAssertEqual(sids, ["good"])
        XCTAssertEqual(mode(events.path), 0o700, "the follower tightens a loose folder of ours")
    }

    func testDefaultHost() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        func host(platform: String, hostname: String, env: String?) throws -> String {
            let code = """
            import importlib.util, socket, sys
            spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
            m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
            m.sys = type("S", (), {"platform": sys.argv[2]})
            socket.gethostname = lambda: sys.argv[3]
            print(m.default_host())
            """
            let (_, out) = try run(["-c", code, script.path, platform, hostname], home: home,
                                   env: env.map { ["CROSSAGENT_HOST": $0] } ?? [:])
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try host(platform: "linux", hostname: "box", env: "studio-2"), "studio-2")
        XCTAssertEqual(try host(platform: "darwin", hostname: "Some-MacBook.local", env: nil), "mac")
        XCTAssertEqual(try host(platform: "linux", hostname: "pc", env: nil), "pc")
        XCTAssertEqual(try host(platform: "linux", hostname: "Build Box.lan", env: nil), "build-box")
        XCTAssertEqual(try host(platform: "linux", hostname: "pc", env: "bad host;rm"), "pc", "an invalid CROSSAGENT_HOST is ignored")
        XCTAssertEqual(try host(platform: "linux", hostname: "", env: nil), "linux")
    }
}

/// Host ids come from hosts.json, nothing assumes "mac" and "pc".
final class GenericHostTests: XCTestCase {
    private let hosts = [
        Host(id: "studio", name: "Mac Studio", type: .local, target: nil, accent: ""),
        Host(id: "gpu-1", name: "GPU Rig", type: .ssh, target: "gpu", accent: ""),
    ]

    func testHostIDs() {
        for ok in ["mac", "pc", "gpu-1", "A_b", String(repeating: "x", count: 40)] { XCTAssertTrue(HostID.isValid(ok), ok) }
        for bad in ["", "a b", "a;b", "ü", "a/b", String(repeating: "x", count: 41)] { XCTAssertFalse(HostID.isValid(bad), bad) }
    }

    func testRemoteHostWords() {
        func r(_ w: String) -> String? { AgentGraph.remoteHost(w, hosts: hosts) }
        XCTAssertEqual(r("gpu-1"), "gpu-1")
        XCTAssertEqual(r("GPU-1"), "gpu-1")
        XCTAssertEqual(r("rig"), "gpu-1", "a word of the name")
        XCTAssertEqual(r("studio"), "studio")
        XCTAssertEqual(r("mac"), "studio", "a word of the local host's name")
        XCTAssertEqual(r("here"), "studio")
        XCTAssertEqual(r("laptop"), "studio")
        XCTAssertEqual(r("remote"), "gpu-1", "the only ssh host")
        XCTAssertEqual(r("overseas"), "gpu-1")
        XCTAssertEqual(r("other_box"), "other_box", "unknown ids pass through")
        XCTAssertNil(r("a;b"))

        let two = hosts + [Host(id: "nas", name: "Home NAS", type: .ssh, target: "nas", accent: "")]
        XCTAssertEqual(AgentGraph.remoteHost("ssh", hosts: two), "ssh", "no single ssh host: the word stays")
        XCTAssertEqual(AgentGraph.remoteHost("nas", hosts: two), "nas")

        XCTAssertEqual(AgentGraph.caRemoteTargets("ca remote rig tests --brief b.md", hosts: hosts), [RemoteTarget(host: "gpu-1", role: "tests")])
        XCTAssertEqual(AgentGraph.caRemoteTargets("ca remote 'a;b' tests", hosts: hosts), [])
        let example = HostStore.example
        XCTAssertEqual(AgentGraph.caRemoteTargets("ca remote ssh tests", hosts: example), [RemoteTarget(host: "pc", role: "tests")])
        XCTAssertEqual(AgentGraph.caRemoteTargets("ca remote linux tests", hosts: example), [RemoteTarget(host: "pc", role: "tests")])
    }

    @MainActor
    func testFallbacksUseTheGraphsHosts() {
        let g = AgentGraph(hosts: hosts)
        XCTAssertEqual(g.orchestratorHost, "studio")
        XCTAssertEqual(g.orchestrator?.hostId, "studio")
        g.apply(AgentEvent(ts: 1, ev: "WorkerStart", sid: "ca-p-studio-lint", role: "worker", node: "lint"))
        XCTAssertEqual(g.nodes["ca-p-studio-lint"]?.hostId, "studio", "a worker event with no host is the orchestrator's")
        g.apply(AgentEvent(ts: 2, ev: "RemoteStart", sid: "ca-p-gpu-1-tests", role: "remote", node: "tests", turn: 1))
        XCTAssertEqual(g.nodes["ca-p-gpu-1-tests"]?.hostId, "gpu-1", "a remote event with no host is the only ssh host's")
        XCTAssertEqual(g.caRemoteTargets("ca remote rig e2e"), [RemoteTarget(host: "gpu-1", role: "e2e")])
        XCTAssertEqual(AgentGraph(orchestratorHost: "pc").orchestratorHost, "pc")
        XCTAssertEqual(AgentGraph(hosts: []).orchestratorHost, "local")
    }
}
