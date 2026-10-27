import XCTest
@testable import CrossAgent

final class HostsTests: XCTestCase {
    func testDefaultsAreOnlyThisMac() {
        XCTAssertEqual(HostStore.defaults.map(\.id), ["mac"])
        XCTAssertTrue(HostStore.defaults.allSatisfy(\.isLocal))
        XCTAssertEqual(HostStore.example.map(\.id), ["mac", "pc"])
    }

    func testIDValidation() {
        XCTAssertTrue(HostStore.isValidID("pc"))
        XCTAssertTrue(HostStore.isValidID("build_box-2"))
        XCTAssertTrue(HostStore.isValidID(String(repeating: "a", count: 40)))
        XCTAssertFalse(HostStore.isValidID(""))
        XCTAssertFalse(HostStore.isValidID(String(repeating: "a", count: 41)))
        XCTAssertFalse(HostStore.isValidID("a b"))
        XCTAssertFalse(HostStore.isValidID("a.b"))
        XCTAssertFalse(HostStore.isValidID("a;rm"))
    }

    func testTargetValidation() {
        for ok in ["pc", "me@host", "me@10.0.0.2", "box.local", "user@[::1]"] {
            XCTAssertTrue(HostStore.isValidTarget(ok), ok)
        }
        for bad in ["", "-oProxyCommand=x", "-p", "a b", "a\tb", "a\nb", "a\u{7f}", "a\u{1b}b", " pc"] {
            XCTAssertFalse(HostStore.isValidTarget(bad), bad.debugDescription)
        }
        XCTAssertFalse(HostStore.isValidTarget(String(repeating: "a", count: 256)))
    }

    func testMakeID() {
        XCTAssertEqual(HostStore.makeID(name: "Linux PC", taken: []), "linux-pc")
        XCTAssertEqual(HostStore.makeID(name: "  Build Box #2! ", taken: []), "build-box-2")
        XCTAssertEqual(HostStore.makeID(name: "Linux PC", taken: ["linux-pc"]), "linux-pc-2")
        XCTAssertEqual(HostStore.makeID(name: "Linux PC", taken: ["linux-pc", "linux-pc-2"]), "linux-pc-3")
        XCTAssertEqual(HostStore.makeID(name: "日本", taken: []), "remote")
        let long = HostStore.makeID(name: String(repeating: "x", count: 60), taken: [String(repeating: "x", count: 40)])
        XCTAssertEqual(long.count, 40)
        XCTAssertTrue(long.hasSuffix("-2"))
        XCTAssertTrue(HostStore.isValidID(long))
    }

    func testParseDropsBadHosts() {
        let json = """
        {"hosts": [
          {"id": "mac", "name": "This Mac", "type": "local", "accent": "#6ea8fe"},
          {"id": "pc", "name": "PC", "type": "ssh", "target": "pc", "accent": "#5fd39a"},
          {"id": "evil", "name": "x", "type": "ssh", "target": "-oProxyCommand=touch /tmp/x", "accent": "#fff"},
          {"id": "bad id", "name": "x", "type": "local", "accent": "#fff"}
        ]}
        """
        XCTAssertEqual(HostStore.parse(Data(json.utf8)).map(\.id), ["mac", "pc"])
        XCTAssertEqual(HostStore.parse(Data("nope".utf8)), [])
    }

    func testAddingKeepsOtherEntriesAndKeys() throws {
        let json = ##"{"hosts":[{"id":"mac","name":"This Mac","type":"local","accent":"#6ea8fe","extra":1}],"note":"mine"}"##
        let box = CrossAgent.Host(id: "box", name: "Box", type: .ssh, target: "me@box", accent: "#5fd39a")
        let out = try HostStore.adding(box, to: Data(json.utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(root["note"] as? String, "mine")
        let hosts = try XCTUnwrap(root["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts.map { $0["id"] as? String }, ["mac", "box"])
        XCTAssertEqual(hosts[0]["extra"] as? Int, 1)
        XCTAssertEqual(HostStore.parse(out).map(\.target), [nil, "me@box"])
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("\n"), "pretty printed")
    }

    func testAddingToNoFileStartsFromDefaults() throws {
        let box = CrossAgent.Host(id: "box", name: "Box", type: .ssh, target: "box", accent: "#5fd39a")
        XCTAssertEqual(HostStore.parse(try HostStore.adding(box, to: nil)).map(\.id), ["mac", "box"])
    }

    func testAddingRefusesBadInput() {
        let file = Data(##"{"hosts":[{"id":"mac","name":"This Mac","type":"local","accent":"#6ea8fe"}]}"##.utf8)
        func add(_ h: CrossAgent.Host, _ data: Data? = file) -> HostStore.AddError? {
            do { _ = try HostStore.adding(h, to: data); return nil } catch { return error as? HostStore.AddError }
        }
        XCTAssertEqual(add(CrossAgent.Host(id: "mac", name: "M", type: .ssh, target: "m", accent: "")), .duplicateID)
        XCTAssertEqual(add(CrossAgent.Host(id: "a b", name: "M", type: .ssh, target: "m", accent: "")), .badID)
        XCTAssertEqual(add(CrossAgent.Host(id: "m", name: "M", type: .ssh, target: "-oX=y", accent: "")), .badTarget)
        XCTAssertEqual(add(CrossAgent.Host(id: "m", name: "M", type: .ssh, target: nil, accent: "")), .badTarget)
        XCTAssertEqual(add(CrossAgent.Host(id: "m", name: "  ", type: .ssh, target: "m", accent: "")), .badName)
        XCTAssertEqual(add(CrossAgent.Host(id: "m", name: "M", type: .ssh, target: "m", accent: ""), Data("[".utf8)), .unreadable)
    }

    func testNeedsSetup() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "HostsTests-\(UUID().uuidString)"))
        XCTAssertTrue(HostStore.needsSetup(HostStore.defaults, defaults: store))
        XCTAssertFalse(HostStore.needsSetup(HostStore.example, defaults: store))
        store.set(true, forKey: HostStore.setupDismissedKey)
        XCTAssertFalse(HostStore.needsSetup(HostStore.defaults, defaults: store))
    }

    func testProbeCommand() {
        let c = HostProbe.command(target: "me@box")
        XCTAssertEqual(c.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(c.args.prefix(5)), ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"])
        XCTAssertEqual(c.args[c.args.count - 2], "me@box")
        XCTAssertTrue(c.args.last!.contains("command -v tmux; command -v claude"))
    }

    func testProbeParse() {
        XCTAssertEqual(HostProbe.parse(status: 0, stdout: "/usr/bin/tmux\n/home/me/.local/bin/claude\n", stderr: ""),
                       .init(reachable: true, tmux: true, claude: true))
        XCTAssertEqual(HostProbe.parse(status: 0, stdout: "/usr/bin/tmux\n", stderr: ""),
                       .init(reachable: true, tmux: true, claude: false))
        let down = HostProbe.parse(status: 255, stdout: "", stderr: "warn\nssh: connect to host box port 22: Connection refused\n")
        XCTAssertFalse(down.reachable)
        XCTAssertEqual(down.error, "ssh: connect to host box port 22: Connection refused")
    }

    /// Hosts built in code skip `load`, so the command builder checks the target itself.
    func testSSHCommandsEndOptionsAndRefuseBadTargets() {
        let good = CrossAgent.Host(id: "box", name: "Box", type: .ssh, target: "me@box", accent: "")
        for c in [CommandBuilder.command(host: good, mode: .shell, session: "ca-box-1"),
                  CommandBuilder.oneShot(host: good, script: "true")] {
            XCTAssertEqual(c.executable, "/usr/bin/ssh")
            XCTAssertEqual(c.args[c.args.count - 3], "--")
            XCTAssertEqual(c.args[c.args.count - 2], "me@box")
        }
        let evil = CrossAgent.Host(id: "evil", name: "Evil", type: .ssh, target: "-oProxyCommand=touch x", accent: "")
        for c in [CommandBuilder.command(host: evil, mode: .shell, session: "ca-evil-1"),
                  CommandBuilder.oneShot(host: evil, script: "true"),
                  CommandBuilder.killCommand(host: evil, session: "ca-evil-1")] {
            XCTAssertNotEqual(c.executable, "/usr/bin/ssh")
            XCTAssertFalse(c.args.contains { $0.contains("ProxyCommand") })
            let r = Runner.runSync(c, timeout: 5)
            XCTAssertEqual(r.status, 255)
            XCTAssertTrue(r.stderr.contains("isn't valid"), r.stderr)
        }
        let probe = HostProbe.command(target: "me@box")
        XCTAssertEqual(probe.args[probe.args.count - 3], "--")
    }
}
