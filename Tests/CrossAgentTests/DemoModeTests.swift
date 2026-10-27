import XCTest
@testable import CrossAgent

final class DemoModeTests: XCTestCase {
    func testDemoSpawnIsLocalCleanAndOnTheDemoTmux() {
        let cmd = DemoMode.spawn(script: "tmux ls")
        XCTAssertEqual(cmd.executable, "/usr/bin/env")
        XCTAssertEqual(cmd.args.first, "-i")
        XCTAssertFalse(cmd.args.contains { $0.contains("ssh") })
        XCTAssertTrue(cmd.args.contains("HOME=" + DemoMode.home.path))
        let path = cmd.args.first { $0.hasPrefix("PATH=") } ?? ""
        XCTAssertTrue(path.hasPrefix("PATH=" + DemoMode.binDir.path + ":"))
        XCTAssertFalse(path.contains("homebrew"))
        XCTAssertEqual(Array(cmd.args.suffix(5)), ["/bin/bash", "--noprofile", "--norc", "-c", "tmux ls"])
    }

    func testDemoScriptsAreInTheCheckout() {
        for name in ["tmux", "claude", "demo-shell", "whoami", "hostname"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: DemoMode.binDir.appendingPathComponent(name).path), name)
        }
        let wrapper = (try? String(contentsOf: DemoMode.binDir.appendingPathComponent("tmux"), encoding: .utf8)) ?? ""
        XCTAssertTrue(wrapper.contains("-L \(DemoMode.tmuxSocket)"))
    }

    func testDemoHostsAndRecents() {
        XCTAssertEqual(HostStore.demo.map(\.id), ["mac", "pc"])
        XCTAssertEqual(HostStore.demo.map(\.name), ["Mac", "PC"])
        XCTAssertEqual(DemoMode.recents().map(\.name), ["demo", "api", "site"])
        XCTAssertTrue(DemoMode.isDemoProject(DemoMode.projectURL.path))
        XCTAssertFalse(DemoMode.isDemoProject(DemoMode.projectsDir.appendingPathComponent("api").path))
    }

    func testTmuxArgsAreEmptyOutsideADemo() {
        XCTAssertFalse(DemoMode.isOn)
        XCTAssertEqual(DemoMode.tmuxArgs, [])
    }
}
