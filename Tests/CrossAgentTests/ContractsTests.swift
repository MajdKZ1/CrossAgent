@testable import CrossAgent
import XCTest

final class ContractsTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(ProjectSlug.make("CrossAgent"), "crossagent")
        XCTAssertEqual(ProjectSlug.make("My App (v2)!"), "my-app-v2")
        XCTAssertEqual(ProjectSlug.make("__"), "project")
        XCTAssertEqual(ProjectSlug.make("a-very-long-project-name-here"), "a-very-long-proj")
        XCTAssertEqual(ProjectSlug.make("abcdefghijklmno-x"), "abcdefghijklmno")
    }

    func testSessionNames() {
        let hosts = ["mac", "pc"]
        XCTAssertEqual(CASessionName.make(slug: "app", host: "pc", task: "1"), "ca-app-pc-1")
        XCTAssertEqual(CASessionName.orchestrator(slug: "app", host: "mac"), "ca-app-mac-orch")
        XCTAssertTrue(CASessionName.parse("ca-pc-1", hostIDs: hosts)! == (nil, "pc", "1"))
        XCTAssertTrue(CASessionName.parse("ca-mac-tests", hostIDs: hosts)! == (nil, "mac", "tests"))
        XCTAssertTrue(CASessionName.parse("ca-app-pc-1", hostIDs: hosts)! == ("app", "pc", "1"))
        XCTAssertTrue(CASessionName.parse("ca-my-app-mac-build-x", hostIDs: hosts)! == ("my-app", "mac", "build-x"))
        XCTAssertTrue(CASessionName.parse("ca-pc-mac-1", hostIDs: hosts)! == ("pc", "mac", "1"))
        XCTAssertNil(CASessionName.parse("other", hostIDs: hosts))
    }
}
