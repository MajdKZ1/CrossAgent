import XCTest
@testable import CrossAgent

@MainActor
final class TabsTests: XCTestCase {
    private func makeApp() -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-tabs-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "ca-tabs-\(UUID().uuidString)")!
        return AppState(hosts: HostStore.example, store: ProjectStore(defaults: defaults, stateDir: dir))
    }

    /// A project with a graph, set up by hand so nothing is spawned or followed.
    private func withProject(_ app: AppState) -> AgentGraph {
        let p = Project(path: "/tmp/ca-tabs-x", home: "/tmp", config: nil)
        app.project = p
        app.setUpOrchestrator(for: p, on: false)
        app.restoreTabs(ProjectState())
        let g = app.orch!.graph
        let now = Date()
        g.nodes["orchestrator"]?.tmuxSession = "ca-x-mac-orch"
        g.nodes["ca-x-pc-build"] = AgentNode(id: "ca-x-pc-build", name: "build", kind: .worker, hostId: "pc", state: .working,
                                             activity: "", tmuxSession: "ca-x-pc-build", startedAt: now, updatedAt: now)
        g.nodes["a1"] = AgentNode(id: "a1", name: "scout", kind: .subagent, hostId: "mac", state: .thinking,
                                  activity: "", startedAt: now, updatedAt: now)
        return g
    }

    func testSavedTabsRoundTripAndSkipUnknownKinds() throws {
        let tabs = [Tab(kind: .panes, id: "p"), Tab(kind: .agent(.session(host: "pc", name: "ca-x-pc-1")), id: "s"),
                    Tab(kind: .agent(.node("a1")), id: "n")]
        let s = ProjectState(mode: "agent", tabs: tabs, selectedTab: "s")
        let back = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)

        // A kind this build doesn't know drops only that tab.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        var list = json["tabs"] as! [[String: Any]]
        list.insert(["id": "z", "kind": ["hologram": [:]], "title": "?", "icon": "x"], at: 1)
        json["tabs"] = list
        let lossy = try JSONDecoder().decode(ProjectState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(lossy.tabs?.map(\.id), ["p", "s", "n"])
    }

    func testRestoreKeepsPanesAndMapsOldMode() {
        let app = makeApp()
        // Old files only had a mode.
        app.restoreTabs(ProjectState(mode: "orchestrator"))
        XCTAssertEqual(app.tabs.map(\.kind), [.panes, .orchestrator])
        XCTAssertEqual(app.selectedTab?.kind, .orchestrator)
        XCTAssertEqual(app.mode, .orchestrator)

        // Panes comes back if missing; unknown hosts, dev tabs and duplicates go.
        let saved = [Tab(kind: .station, id: "st"), Tab(kind: .agent(.session(host: "nope", name: "x")), id: "a"),
                     Tab(kind: .dev(.mascotGallery), id: "d"), Tab(kind: .station, id: "st2")]
        app.restoreTabs(ProjectState(tabs: saved, selectedTab: "st"))
        XCTAssertEqual(app.tabs.map(\.kind), [.panes, .station])
        XCTAssertEqual(app.selectedTabID, "st")
    }

    func testCanonicalRefsDedupeNodeAndSession() {
        let app = makeApp()
        _ = withProject(app)
        XCTAssertEqual(app.canonical(.node("ca-x-pc-build")), .session(host: "pc", name: "ca-x-pc-build"))
        XCTAssertEqual(app.canonical(.session(host: "mac", name: "ca-x-mac-orch")), .node("orchestrator"))
        XCTAssertEqual(app.canonical(.node("a1")), .node("a1"))
        // Same name on another host is another session.
        XCTAssertEqual(app.canonical(.session(host: "pc", name: "ca-x-mac-orch")), .session(host: "pc", name: "ca-x-mac-orch"))
    }

    func testOpenSelectCloseAndMove() {
        let app = makeApp()
        _ = withProject(app)
        app.openAgent(.node("a1"))
        app.openAgent(.node("a1"))
        app.open(.station)
        app.openAgent(.node("orchestrator"))
        XCTAssertEqual(app.tabs.count, 4)
        XCTAssertEqual(app.mode, .agent)
        XCTAssertEqual(app.title(of: app.tabs[1]), "scout")

        app.select(index: 0)
        XCTAssertEqual(app.mode, .panes)
        app.closeTab(app.tabs[0].id)
        XCTAssertEqual(app.tabs.count, 4, "Panes can't be closed")

        app.moveTab(from: 3, to: 1)
        XCTAssertEqual(app.tabs.map(\.kind)[1], .agent(.node("orchestrator")))

        app.select(app.tabs[2].id)
        let station = app.tabs.first { $0.kind == .station }!.id
        app.select(station)
        app.closeTab()
        XCTAssertEqual(app.tabs.count, 3)
        XCTAssertEqual(app.selectedTab?.kind, .agent(.node("a1")), "closing goes back to the tab before")

        app.openAgent(.node("gone"))
        XCTAssertEqual(app.tabs.count, 3)
    }

    func testStripWidthsShrinkThenScroll() {
        // Room to spare: every tab at the cap.
        XCTAssertEqual(TabStrip.widths(count: 3, selected: 0, available: 1000), [150, 150, 150])
        // Tight: the selected tab stays readable, the rest share what's left.
        let w = TabStrip.widths(count: 8, selected: 2, available: 700)!
        XCTAssertEqual(w[2], TabStrip.selectedMin)
        XCTAssertTrue(w.enumerated().allSatisfy { $0.offset == 2 || $0.element >= TabStrip.minWidth })
        XCTAssertEqual(w.reduce(0, +) + TabStrip.gap * 7, 700, accuracy: 0.01)
        // Too many for the minimum: nil, the strip scrolls.
        XCTAssertNil(TabStrip.widths(count: 8, selected: 0, available: 500))
        XCTAssertEqual(TabStrip.widths(count: 0, selected: nil, available: 300), [])
    }

    func testCmd9GoesToTheLastTab() {
        let app = makeApp()
        _ = withProject(app)
        app.open(.station)
        app.openAgent(.node("a1"))
        app.select(index: 0)
        app.selectTab(shortcut: 8)
        XCTAssertEqual(app.selectedTab?.kind, .agent(.node("a1")))
        app.selectTab(shortcut: 1)
        XCTAssertEqual(app.selectedTab?.kind, .station)
    }
}
