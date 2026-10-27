import XCTest
@testable import CrossAgent

/// A machine added at runtime reaches everything that holds a host list.
@MainActor
final class HostReloadTests: XCTestCase {
    let mac = HostStore.defaults[0]
    /// An ssh host whose target the command builder refuses, so polling it fails fast
    /// without touching the network.
    let box = CrossAgent.Host(id: "box", name: "Build Box", type: .ssh, target: "-nope", accent: "#5fd39a")

    func testAppStateTakesNewHosts() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-reload-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "ca-reload-\(UUID().uuidString)")!
        let app = AppState(hosts: [mac], store: ProjectStore(defaults: defaults, stateDir: dir))
        XCTAssertNil(app.host("box"))
        app.setHosts([mac, box])
        XCTAssertEqual(app.hosts.map(\.id), ["mac", "box"])
        XCTAssertEqual(app.host("box")?.name, "Build Box")
    }

    func testTmuxMonitorPollsAddedHost() async throws {
        let mon = TmuxMonitor(hosts: [mac])
        mon.setHosts([mac, box])
        XCTAssertFalse(mon.isRunning, "a monitor that wasn't started stays stopped")
        mon.start()
        defer { mon.stop() }
        mon.setHosts([mac])
        XCTAssertEqual(mon.hosts.map(\.id), ["mac"])
        mon.setHosts([mac, box])
        for _ in 0..<50 where !mon.hasPolled(host: box) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(mon.reachable["box"], false, "the new host got a poll loop")
        mon.setHosts([mac])
        XCTAssertNil(mon.reachable["box"], "a removed host's state goes with it")
    }

    func testSessionDiscoveryPollsAddedHost() async {
        var polled: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ca-reload-\(UUID().uuidString)")
        let d = SessionDiscovery(hosts: [], localRoot: root.path, defaults: UserDefaults(suiteName: "ca-r-\(UUID())")!) { h, _ in
            polled.append(h.id)
            return SpawnCommand(executable: "/bin/sh", args: ["-c", "echo 'down' >&2; exit 255"])
        }
        await d.refresh()
        XCTAssertEqual(polled, [])
        d.setHosts([box])
        XCTAssertEqual(d.host("box")?.name, "Build Box")
        await d.refresh()
        XCTAssertEqual(polled, ["box"])
        XCTAssertEqual(d.hostErrors["box"], "down")
        d.setHosts([])
        XCTAssertNil(d.hostErrors["box"])
        XCTAssertNil(d.host("box"))
    }

    func testOrchestratorGraphLearnsNewHosts() {
        let graph = AgentGraph(orchestratorHost: "mac", hosts: [mac])
        let c = OrchestratorController(slug: "x", macPath: "/nonexistent-ca-reload", pcRelativePath: "x",
                                       hosts: [mac], graph: graph)
        c.setHosts([mac, box])
        XCTAssertEqual(c.hosts.map(\.id), ["mac", "box"])
        XCTAssertEqual(graph.hosts.map(\.id), ["mac", "box"])
        XCTAssertEqual(c.projectPaths["box"], "x")
        XCTAssertEqual(graph.caRemoteTargets("ca remote box tester --brief b.md").map(\.host), ["box"])
    }

    func testMascotOrbTakesAddedHostColour() {
        let id = "orb-\(UUID().uuidString.prefix(8))"
        let grey = MascotRig.accent(id)
        MascotRig.setAccents([CrossAgent.Host(id: id, name: "Orb", type: .ssh, target: "orb", accent: "#c792ea")])
        XCTAssertNotEqual(MascotRig.accent(id), grey)
        XCTAssertEqual(MascotRig.accent(id), NSColor(hex: "#c792ea").cgColor)
        XCTAssertNotNil(MascotRig.accent("mac"), "hosts already known keep their colour")
    }
}
