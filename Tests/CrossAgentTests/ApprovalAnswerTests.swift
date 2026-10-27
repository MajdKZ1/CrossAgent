import XCTest
@testable import CrossAgent

/// Runs the approval answer script against a scratch HOME.
final class ApprovalAnswerTests: XCTestCase {
    var home: URL!
    let id = "0123456789ab"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("aa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    var approvals: URL { home.appendingPathComponent(".crossagent/approvals") }

    private func answer(allow: Bool = true) -> Runner.Result {
        let script = AppState.answerScript(id: id, allow: allow)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let err = Pipe()
        p.standardError = err
        try? p.run()
        p.waitUntilExit()
        return .init(status: p.terminationStatus, stdout: "",
                     stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func mode(_ url: URL) -> Int {
        var st = stat()
        lstat(url.path, &st)
        return Int(st.st_mode & 0o777)
    }

    private func request() throws {
        try FileManager.default.createDirectory(at: approvals, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: approvals.appendingPathComponent("\(id).json"))
    }

    func testWritesPrivateAnswer() throws {
        try request()
        chmod(approvals.path, 0o755)
        let r = answer(allow: false)
        XCTAssertEqual(r.status, 0, r.stderr)
        let answer = approvals.appendingPathComponent("\(id).answer")
        XCTAssertEqual(try String(contentsOf: answer, encoding: .utf8), "deny")
        XCTAssertEqual(mode(answer), 0o600)
        XCTAssertEqual(mode(approvals), 0o700)
        XCTAssertEqual(mode(home.appendingPathComponent(".crossagent")), 0o700)
        let tmp = try FileManager.default.contentsOfDirectory(atPath: approvals.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(tmp, [])
    }

    func testLateAnswerLeavesNothing() throws {
        let r = answer()
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.stderr.contains("timed out"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: approvals.appendingPathComponent("\(id).answer").path))
        XCTAssertEqual(mode(approvals), 0o700, "made private even so")
    }

    func testPlantedSymlinkIsNotFollowed() throws {
        try request()
        let victim = home.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        let out = approvals.appendingPathComponent("\(id).answer")
        try FileManager.default.createSymbolicLink(at: out, withDestinationURL: victim)
        XCTAssertEqual(answer().status, 0)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep")
        XCTAssertNil(PrivateFiles.check(out.path, directory: false))
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "allow")
    }

    func testSymlinkedApprovalsDirIsRefused() throws {
        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: elsewhere.appendingPathComponent("\(id).json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".crossagent"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: approvals, withDestinationURL: elsewhere)
        let r = answer()
        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.stderr.contains("not a private dir"), r.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("\(id).answer").path))
    }
}
