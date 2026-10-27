@testable import CrossAgent
import XCTest

final class HookInstallerTests: XCTestCase {
    private func json(_ d: Data?) -> [String: Any] {
        (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private let existing = Data(#"""
    {
      "permissions": {"allow": ["Bash(ls:*)"]},
      "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo mine"}]}],
        "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]
      },
      "env": {"FOO": "1"}
    }
    """#.utf8)

    func testInstallIntoNothing() {
        let out = json(HookInstaller.install(into: nil))
        let hooks = out["hooks"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(hooks.keys), Set(HookInstaller.events))
        let pre = (hooks["PreToolUse"] as? [[String: Any]])?.first
        XCTAssertEqual(pre?["matcher"] as? String, "*")
        let cmd = (pre?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(cmd?["command"] as? String, HookInstaller.command)
        XCTAssertEqual(cmd?["async"] as? Bool, true)
        XCTAssertNil((hooks["Stop"] as? [[String: Any]])?.first?["matcher"])
        XCTAssertTrue(HookInstaller.isInstalled(in: HookInstaller.install(into: nil)))
        XCTAssertFalse(HookInstaller.isInstalled(in: existing))
    }

    func testInstallKeepsEverythingElseAndIsIdempotent() {
        let once = HookInstaller.install(into: existing)
        let twice = HookInstaller.install(into: once)
        XCTAssertEqual(once, twice)
        let out = json(once)
        XCTAssertEqual((out["env"] as? [String: String])?["FOO"], "1")
        XCTAssertEqual((out["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        let pre = (out["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 2)
        XCTAssertEqual(pre?.first?["matcher"] as? String, "Bash", "the user's hook stays first")
        let stop = (out["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 2)
    }

    func testRemoveRestoresTheOriginal() {
        let removed = HookInstaller.remove(from: HookInstaller.install(into: existing))
        XCTAssertEqual(json(removed) as NSDictionary, json(existing) as NSDictionary)
        XCTAssertNil(HookInstaller.remove(from: HookInstaller.install(into: nil)), "nothing left means delete the file")
        XCTAssertNil(HookInstaller.remove(from: Data("{}".utf8)))
    }

    func testRemoveOnlyOurCommandInASharedGroup() {
        let shared = Data(#"""
        {"hooks": {"Stop": [{"hooks": [
          {"type": "command", "command": "say done"},
          {"type": "command", "command": "python3 -I \"$HOME/.crossagent/bin/crossagent-hook.py\""}
        ]}]}}
        """#.utf8)
        let out = json(HookInstaller.remove(from: shared))
        let list = (((out["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"]) as? [[String: Any]]
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?["command"] as? String, "say done")
    }

    func testBrokenJSONIsLeftAlone() {
        let bad = Data("{ not json".utf8)
        XCTAssertEqual(HookInstaller.remove(from: bad), bad)
        XCTAssertFalse(HookInstaller.isInstalled(in: bad))
    }

    func testFileHelpers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let url = HookInstaller.settingsURL(projectPath: dir.path)
        try existing.write(to: url)
        try HookInstaller.installHooks(projectPath: dir.path)
        XCTAssertTrue(HookInstaller.hooksInstalled(projectPath: dir.path))
        try HookInstaller.removeHooks(projectPath: dir.path)
        XCTAssertFalse(HookInstaller.hooksInstalled(projectPath: dir.path))
        XCTAssertEqual(json(try Data(contentsOf: url)) as NSDictionary, json(existing) as NSDictionary)

        let empty = dir.appendingPathComponent("fresh")
        try HookInstaller.installHooks(projectPath: empty.path)
        try HookInstaller.removeHooks(projectPath: empty.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HookInstaller.settingsURL(projectPath: empty.path).path))
    }
}

/// Runs the real crossagent-hook.py on the captured payloads. Skipped without python3.
final class HookScriptTests: XCTestCase {
    private var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CrossAgent/Resources/crossagent-hook.py")
    }

    private func python() throws -> String {
        for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        throw XCTSkip("no python3")
    }

    private func runHook(_ py: String, home: URL, payload: Data) throws -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = ["-I", script.path]
        p.environment = ["HOME": home.path, "CROSSAGENT_ROLE": "orchestrator", "CROSSAGENT_PROJECT": "proj", "CROSSAGENT_HOST": "mac"]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = out
        try p.run()
        try inp.fileHandleForWriting.write(contentsOf: payload)
        try inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    @MainActor
    func testScriptTurnsPayloadsIntoTheFixtureEvents() throws {
        let py = try python()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ca-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        for (raw, sid, expected) in [(HookFixtures.rawPrint, "s-print", HookFixtures.eventsPrint),
                                     (HookFixtures.rawTTY, "s-tty", HookFixtures.eventsTTY)] {
            for line in raw.split(separator: "\n") {
                let (rc, out) = try runHook(py, home: home, payload: Data(line.utf8))
                XCTAssertEqual(rc, 0)
                XCTAssertTrue(out.isEmpty, "the hook must print nothing")
            }
            let file = home.appendingPathComponent(".crossagent/events/\(sid).jsonl")
            var got = HookFixtures.events(try String(contentsOf: file, encoding: .utf8))
            for i in got.indices { got[i].ts = 1000 + Double(i) }
            XCTAssertEqual(got, HookFixtures.events(expected))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600)
        }
        let dirMode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".crossagent/events").path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
    }

    func testScriptSurvivesGarbage() throws {
        let py = try python()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ca-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for junk in ["", "nope", "[1,2]", #"{"hook_event_name": 5}"#, String(repeating: "x", count: 100_000)] {
            let (rc, out) = try runHook(py, home: home, payload: Data(junk.utf8))
            XCTAssertEqual(rc, 0)
            XCTAssertTrue(out.isEmpty)
        }
    }
}
