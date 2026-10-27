import XCTest
@testable import CrossAgent

@MainActor
final class WorkerActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func info(_ name: String, command: String = "bash", status: SessionStatus = .idle, claude: Bool = false,
                      dead: Bool = false, lastOutput: Date? = nil) -> TmuxSessionInfo {
        TmuxSessionInfo(hostId: "mac", name: name, createdAt: t0, lastActivity: lastOutput ?? t0, currentCommand: command,
                        paneDead: dead, attachedClients: 0, cols: 80, rows: 24, capture: "", status: status,
                        isClaude: claude)
    }

    private func worker(_ g: AgentGraph, _ task: String, _ state: AgentState, recent: [String] = []) -> String {
        let id = "ca-p-mac-\(task)"
        g.nodes[id] = AgentNode(id: id, name: task, kind: .worker, hostId: "mac", state: state, activity: "Running yes",
                                tmuxSession: id, recent: recent, startedAt: t0, updatedAt: t0)
        return id
    }

    func testBusyRule() {
        // A command worker runs until its WorkerStop, whatever tmux shows in front.
        XCTAssertTrue(AgentGraph.workerBusy(info("a")))
        XCTAssertTrue(AgentGraph.workerBusy(info("a", status: .running)))
        XCTAssertFalse(AgentGraph.workerBusy(info("a", status: .waitingForInput)))
        XCTAssertFalse(AgentGraph.workerBusy(info("a", dead: true)))
    }

    func testBusyWorkerStaysWorkingPastIdleTimeout() {
        let g = AgentGraph()
        let busy = worker(g, "busy", .working)
        let gone = worker(g, "gone", .working)
        // Polls every 10 s keep the busy one fresh; one whose pane died dozes off after idleAfter.
        for s in stride(from: 10.0, through: 60, by: 10) {
            let now = t0.addingTimeInterval(s)
            g.keepBusyWorkers(["mac": [info(busy), info(gone, dead: true)]], now: now)
            g.tick(now: now)
        }
        XCTAssertEqual(g.nodes[busy]?.state, .working)
        XCTAssertEqual(g.nodes[gone]?.state, .idle)
    }

    func testIdleCommandWorkerWakes() {
        let g = AgentGraph()
        let cmd = worker(g, "cmd", .idle)
        g.keepBusyWorkers(["mac": [info(cmd)]], now: t0.addingTimeInterval(5))
        XCTAssertEqual(g.nodes[cmd]?.state, .working)
        XCTAssertEqual(g.nodes[cmd]?.activity, "Running yes")
    }

    func testRemoteWorkersAreLeftToTheirTurn() {
        let g = AgentGraph()
        let id = worker(g, "tests", .idle)
        g.nodes[id]?.remote = RemoteInfo(host: "mac", role: "tests", tmuxSession: id)
        g.keepBusyWorkers(["mac": [info(id)]], now: t0.addingTimeInterval(5))
        XCTAssertEqual(g.nodes[id]?.state, .idle)
    }

    func testFinishedAndWaitingWorkersAreLeftAlone() {
        let g = AgentGraph()
        let done = worker(g, "done", .done)
        let ask = worker(g, "ask", .needsInput("Allow?"))
        g.keepBusyWorkers(["mac": [info(done, status: .running), info(ask, status: .running)]], now: t0.addingTimeInterval(5))
        XCTAssertEqual(g.nodes[done]?.state, .done)
        XCTAssertEqual(g.nodes[ask]?.state, .needsInput("Allow?"))
    }
}
