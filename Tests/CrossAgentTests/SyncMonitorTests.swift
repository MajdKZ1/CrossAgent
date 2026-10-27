import XCTest
@testable import CrossAgent

final class SyncMonitorTests: XCTestCase {
    // Real Mutagen 0.18.1 output (trimmed).
    let fixture = """
    [{"identifier":"sync_2UW","version":1,"creationTime":"2026-10-27T07:19:27.115446Z","creatingVersion":"0.18.1",
     "alpha":{"protocol":"local","path":"/Users/me/Projects/x","connected":true,"scanned":true,"directories":1,"files":1,"totalFileSize":3},
     "beta":{"protocol":"ssh","host":"pc","path":"~/Projects/x","connected":true,"scanned":true,
       "transitionProblems":[{"path":"","error":"unable to walk to transition root parent: ..."}]},
     "mode":"two-way-safe","name":"ca-x","paused":false,"status":"watching","successfulCycles":2,
     "conflicts":[{"root":"a.txt","alphaChanges":[{"path":"a.txt","old":{"kind":"file","digest":"55ca"},"new":{"kind":"file","digest":"282f"}}],
       "betaChanges":[{"path":"a.txt","old":{"kind":"file","digest":"55ca"},"new":{"kind":"file","digest":"0f27"}}]}],
     "lastError":"optional string","labels":{"ca-cfg":"abc123"}},
     {"identifier":"sync_other","name":"not-ours","status":"watching"}]
    """

    private func session(_ json: String) -> SyncSession? {
        SyncSession.parse(Data("[\(json)]".utf8)).first
    }

    func testDecodesFixture() throws {
        let all = SyncSession.parse(Data(fixture.utf8))
        XCTAssertEqual(all.count, 1, "only ca-* sessions are kept")
        let s = try XCTUnwrap(all.first)
        XCTAssertEqual(s.project, "x")
        XCTAssertEqual(s.statusWord, "watching")
        XCTAssertEqual(s.alpha?.display, "/Users/me/Projects/x")
        XCTAssertEqual(s.beta?.display, "pc:~/Projects/x")
        XCTAssertEqual(s.problems, ["unable to walk to transition root parent: ..."])
        XCTAssertEqual(s.conflictRoots, ["a.txt"])
        XCTAssertEqual(s.error, "optional string")
        XCTAssertEqual(s.health, .problem)
    }

    func testColors() {
        let clean = #""name":"ca-a","alpha":{"path":"/a"},"beta":{"path":"/b"}"#
        XCTAssertEqual(session(#"{\#(clean),"status":"watching","paused":false}"#)?.health, .ok)
        XCTAssertEqual(session(#"{\#(clean),"status":"watching","paused":true}"#)?.health, .busy)
        XCTAssertEqual(session(#"{\#(clean),"status":"staging-alpha"}"#)?.health, .busy)
        XCTAssertEqual(session(#"{\#(clean),"status":"connecting-beta"}"#)?.health, .busy)
        // Connecting at launch often still carries the last error: amber, not red.
        XCTAssertEqual(session(#"{\#(clean),"status":"connecting-beta","lastError":"ssh: connection refused"}"#)?.health, .busy)
        XCTAssertEqual(session(#"{\#(clean),"status":"connecting-alpha","conflicts":[{"root":"a.txt"}]}"#)?.health, .problem)
        XCTAssertEqual(session(#"{\#(clean),"status":"something-new"}"#)?.health, .busy)
        XCTAssertEqual(session(#"{\#(clean),"status":"watching","conflicts":[{"root":"a.txt"}]}"#)?.health, .problem)
        XCTAssertEqual(session(#"{\#(clean),"status":"watching","excludedConflicts":3}"#)?.health, .problem)
        XCTAssertEqual(session(#"{\#(clean),"status":"disconnected"}"#)?.health, .problem)
        XCTAssertEqual(session(#"{\#(clean),"status":"halted-on-root-emptied"}"#)?.health, .problem)
        XCTAssertEqual(session(#"{"name":"ca-a","status":"watching","alpha":{"scanProblems":[{"path":"x","error":"e"}]}}"#)?.health, .ok)
        XCTAssertEqual(session(#"{"name":"ca-a","status":"watching","beta":{"transitionProblems":[{"path":"x","error":"e"}]}}"#)?.health, .problem)
        XCTAssertEqual(session(#"{\#(clean),"status":"watching","lastError":""}"#)?.health, .ok)
    }

    func testLenient() {
        XCTAssertTrue(SyncSession.parse(Data()).isEmpty)
        XCTAssertTrue(SyncSession.parse(Data("[]".utf8)).isEmpty)
        XCTAssertTrue(SyncSession.parse(Data("not json".utf8)).isEmpty)
        // Wrong types for single fields don't drop the session.
        let s = session(#"{"name":"ca-a","status":"watching","paused":"no","conflicts":5,"beta":{"host":"pc","path":7}}"#)
        XCTAssertEqual(s?.health, .ok)
        XCTAssertEqual(s?.beta?.display, "pc:?")
    }
}
