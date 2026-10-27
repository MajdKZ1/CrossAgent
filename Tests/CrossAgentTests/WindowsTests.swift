import XCTest
@testable import CrossAgent

@MainActor
final class WindowsTests: XCTestCase {
    private func makeStore() -> ProjectStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-win-\(UUID().uuidString)")
        return ProjectStore(defaults: UserDefaults(suiteName: "ca-win-\(UUID().uuidString)")!, stateDir: dir)
    }

    private func makeFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ca-win-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL.path
    }

    func testRestoreFallsBackToLastProjectThenUsesOpenList() throws {
        let store = makeStore()
        XCTAssertEqual(store.pathsToRestore(), [])
        let a = try makeFolder(), b = try makeFolder()

        // Before windows there was only the last project.
        store.lastProjectPath = a
        XCTAssertEqual(store.pathsToRestore(), [a])

        // Once the open list is saved it wins, even empty (welcome on relaunch).
        store.openProjectPaths = [b, a, b, "/nope/gone"]
        XCTAssertEqual(store.pathsToRestore(), [b, a])
        store.openProjectPaths = []
        XCTAssertEqual(store.pathsToRestore(), [])
    }

    func testFrameNamesAreStablePerPathAndHideIt() {
        let a = ProjectWindows.frameName(path: "/Users/me/code/app")
        XCTAssertEqual(a, ProjectWindows.frameName(path: "/Users/me/code/app"))
        XCTAssertNotEqual(a, ProjectWindows.frameName(path: "/Users/me/code/app2"))
        XCTAssertFalse(a.contains("app"))
        XCTAssertNotEqual(a, ProjectWindows.welcomeFrameName)
    }

    func testMonitorStaysFastUntilEveryViewerLetsGo() {
        let mon = TmuxMonitor(hosts: [])
        // Two windows with a station tab, plus one canvas waiting on a prompt.
        mon.setActive(true)
        mon.setActive(true)
        mon.setActive(true, for: "canvas")
        mon.setActive(false)
        XCTAssertTrue(mon.isActive)
        mon.setActive(false, for: "canvas")
        XCTAssertTrue(mon.isActive)
        mon.setActive(false)
        XCTAssertFalse(mon.isActive)
        // An extra release doesn't go negative and swallow the next hold.
        mon.setActive(false)
        mon.setActive(true)
        XCTAssertTrue(mon.isActive)
    }

    func testCloseProjectSavesTabsAndAWindowKeepsItsProject() throws {
        let path = try makeFolder()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-win-state-\(UUID().uuidString)")
        let store = ProjectStore(defaults: UserDefaults(suiteName: "ca-win-\(UUID().uuidString)")!, stateDir: dir)
        let app = AppState(hosts: HostStore.example, store: store)
        let p = Project(url: URL(fileURLWithPath: path))
        app.openProject(p.url)
        app.open(.station)
        app.closeProject()
        let saved = store.loadState(for: p)
        XCTAssertEqual(saved.tabs?.map(\.kind), [.panes, .station])
        // A window holds one project: opening another into it does nothing.
        let other = try makeFolder()
        let app2 = AppState(hosts: HostStore.example, store: store)
        app2.openProject(p.url)
        app2.openProject(URL(fileURLWithPath: other))
        XCTAssertEqual(app2.project?.path, p.path)
        app2.closeProject()
    }
}
