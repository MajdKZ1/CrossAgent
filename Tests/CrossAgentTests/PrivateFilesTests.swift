import XCTest
@testable import CrossAgent

final class PrivateFilesTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        // Not under /tmp: the user's own temp dir, private like the rest.
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode(_ url: URL) -> Int {
        var st = stat()
        lstat(url.path, &st)
        return Int(st.st_mode & 0o777)
    }

    func testEnsureDirCreatesPrivateParents() {
        let d = dir.appendingPathComponent("a/b/c")
        XCTAssertNil(PrivateFiles.ensureDir(d))
        XCTAssertEqual(mode(d), 0o700)
        XCTAssertEqual(mode(dir.appendingPathComponent("a")), 0o700)
        XCTAssertNil(PrivateFiles.check(d.path, directory: true))
    }

    func testEnsureDirTightensLooseDir() {
        let d = dir.appendingPathComponent("loose")
        mkdir(d.path, 0o777)
        chmod(d.path, 0o777)
        XCTAssertEqual(PrivateFiles.check(d.path, directory: true), .sharedWritable)
        XCTAssertNil(PrivateFiles.ensureDir(d))
        XCTAssertEqual(mode(d), 0o700)
    }

    func testEnsureDirRefusesSymlink() throws {
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(PrivateFiles.ensureDir(link), .symlink)
        XCTAssertEqual(PrivateFiles.check(link.path, directory: true), .symlink)
    }

    func testCheckFile() throws {
        let f = dir.appendingPathComponent("f")
        XCTAssertEqual(PrivateFiles.check(f.path, directory: false), .missing)
        try Data("x".utf8).write(to: f)
        chmod(f.path, 0o644)
        XCTAssertNil(PrivateFiles.check(f.path, directory: false))
        chmod(f.path, 0o664)
        XCTAssertEqual(PrivateFiles.check(f.path, directory: false), .sharedWritable)
        chmod(f.path, 0o646)
        XCTAssertEqual(PrivateFiles.check(f.path, directory: false), .sharedWritable)
        XCTAssertEqual(PrivateFiles.check(f.path, directory: true), .wrongType)
        XCTAssertEqual(PrivateFiles.check(f.path, directory: false, uid: getuid() + 1), .notOwned)
        chmod(f.path, 0o600)
        XCTAssertEqual(PrivateFiles.check(f.path, directory: false, uid: getuid() + 1), .notOwned)
        let link = dir.appendingPathComponent("l")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f)
        XCTAssertEqual(PrivateFiles.check(link.path, directory: false), .symlink)
        XCTAssertFalse(PrivateFiles.isTrusted(file: link.path))
    }

    func testWriteIs0600AndReplacesSymlink() throws {
        let victim = dir.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: victim)
        let f = dir.appendingPathComponent("out.json")
        try FileManager.default.createSymbolicLink(at: f, withDestinationURL: victim)
        try PrivateFiles.write(Data("new".utf8), to: f)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "new")
        XCTAssertNil(PrivateFiles.check(f.path, directory: false))
        XCTAssertEqual(mode(f), 0o600)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(left, [], "no temp files left behind")
    }

    // MARK: ssh control socket

    func testControlPathFitsUsualHomes() {
        XCTAssertEqual(SSH.fittingControlPath(home: "/Users/me"), "~/.crossagent/ssh/%C")
        // 29 characters of home is the longest that fits: 29 + 17 + 40 = 86.
        let longest = "/Users/" + String(repeating: "u", count: 22)
        XCTAssertEqual(longest.count, 29)
        XCTAssertEqual(SSH.fittingControlPath(home: longest), "~/.crossagent/ssh/%C")
    }

    func testControlPathFallsBackForLongHome() {
        let tooLong = "/Users/" + String(repeating: "u", count: 23)
        XCTAssertNil(SSH.fittingControlPath(home: tooLong))
        XCTAssertFalse(SSH.options(controlPath: nil).contains { $0.hasPrefix("Control") })
        XCTAssertEqual(SSH.options(controlPath: nil), ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"])
    }

    func testControlPathNeverInTmp() {
        let opts = SSH.options(controlPath: SSH.fittingControlPath(home: "/Users/me"))
        XCTAssertTrue(opts.contains("ControlPath=~/.crossagent/ssh/%C"))
        XCTAssertFalse(opts.joined(separator: " ").contains("/tmp"))
        XCTAssertFalse(SSH.baseOptions.joined(separator: " ").contains("/tmp"))
    }

    /// A real socket at the longest allowed path binds; one byte more does not.
    func testSocketPathLimit() throws {
        func binds(_ len: Int) -> Bool {
            let base = dir.path + "/"
            let path = base + String(repeating: "s", count: max(1, len - base.utf8.count))
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd); unlink(path) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let cap = MemoryLayout.size(ofValue: addr.sun_path)
            guard path.utf8.count < cap else { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in path.utf8.enumerated() { buf[i] = b }
            }
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
        }
        guard dir.path.utf8.count < 90 else { throw XCTSkip("temp dir path too long to probe") }
        XCTAssertTrue(binds(SSH.maxControlPath + 17))
        XCTAssertFalse(binds(SSH.maxControlPath + 18))
    }
}
