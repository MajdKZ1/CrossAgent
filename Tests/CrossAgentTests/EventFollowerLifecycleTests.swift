import XCTest
@testable import CrossAgent

final class EventFollowerLifecycleTests: XCTestCase {
    /// Regression: stopping used to leave the stdout handler on a pipe at EOF, which then
    /// fired nonstop. Same bug and fix as RemoteSampler.
    @MainActor
    func testStartStopLeaksNoHandlerOrProcess() async throws {
        let marker = "ca-follower-test-\(UUID().uuidString.prefix(8))"
        let script = #"trap 'exit 0' TERM; i=0; while :; do i=$((i+1)); echo "{\"ts\":$i,\"ev\":\"Tick\"}"; sleep 0.05; done"#
        let fake = SpawnCommand(executable: "/bin/sh", args: ["-c", script, marker])
        let mac = Host(id: "mac", name: "This Mac", type: .local, target: nil, accent: "#6ea8fe")
        var events = 0
        let follower = EventFollower(host: mac, replay: 0, command: { _ in fake }) { batch in
            events += batch.count
        }
        for _ in 0..<20 {
            follower.start()
            try await Task.sleep(nanoseconds: 150_000_000)
            follower.stop()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        follower.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        follower.shutdown()
        XCTAssertGreaterThan(events, 0, "the fake follower should have streamed")
        XCTAssertEqual(ActivityTests.processes(matching: marker), "", "shutdown waits for the process")

        try await Task.sleep(nanoseconds: 500_000_000)
        let before = ActivityTests.cpuSeconds()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let used = ActivityTests.cpuSeconds() - before
        XCTAssertLessThan(used, 0.2, "CPU while stopped should be flat, got \(used) s over 2 s")
        XCTAssertEqual(ActivityTests.processes(matching: marker), "")
    }
}
