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
        let now = t0.addingTimeInterval(100)
        // A command worker runs until its WorkerStop, whatever tmux shows in front.
        XCTAssertTrue(AgentGraph.workerBusy(info("a"), claude: false, now: now))
        XCTAssertTrue(AgentGraph.workerBusy(info("a", status: .running), claude: false, now: now))
        XCTAssertFalse(AgentGraph.workerBusy(info("a", status: .waitingForInput), claude: false, now: now))
        XCTAssertFalse(AgentGraph.workerBusy(info("a", dead: true), claude: false, now: now))
        // Claude goes by its last output, not by a status a slow poll may have kept around.
        XCTAssertTrue(AgentGraph.workerBusy(info("c", status: .running, lastOutput: now.addingTimeInterval(-3)),
                                            claude: true, now: now))
        XCTAssertFalse(AgentGraph.workerBusy(info("c", status: .running, lastOutput: now.addingTimeInterval(-60)),
                                             claude: true, now: now))
    }

    func testBusyWorkerStaysWorkingPastIdleTimeout() {
        let g = AgentGraph()
        let busy = worker(g, "busy", .working)
        let quiet = worker(g, "quiet", .working)
        // Polls every 10 s keep the busy one fresh; the quiet Claude dozes off after idleAfter.
        for s in stride(from: 10.0, through: 60, by: 10) {
            let now = t0.addingTimeInterval(s)
            g.keepBusyWorkers(["mac": [info(busy, command: "bash"),
                                       info(quiet, command: "2.1.311", claude: true, lastOutput: t0)]], now: now)
            g.tick(now: now)
        }
        XCTAssertEqual(g.nodes[busy]?.state, .working)
        XCTAssertEqual(g.nodes[quiet]?.state, .idle)
    }

    func testIdleCommandWorkerWakesButIdleClaudeStaysIdle() {
        let g = AgentGraph()
        let cmd = worker(g, "cmd", .idle)
        let claude = worker(g, "claude", .idle, recent: ["hi"])
        let now = t0.addingTimeInterval(5)
        // Claude at its prompt redraws now and then; its Stop said idle, so it stays idle.
        g.keepBusyWorkers(["mac": [info(cmd), info(claude, command: "2.1.311", claude: true, lastOutput: now)]], now: now)
        XCTAssertEqual(g.nodes[cmd]?.state, .working)
        XCTAssertEqual(g.nodes[cmd]?.activity, "Running yes")
        XCTAssertEqual(g.nodes[claude]?.state, .idle)
    }

    func testWorkingClaudeInALongToolCallStaysWorking() {
        let g = AgentGraph()
        let id = worker(g, "claude", .working)
        for s in stride(from: 10.0, through: 90, by: 10) {
            let now = t0.addingTimeInterval(s)
            // The spinner keeps the screen moving.
            g.keepBusyWorkers(["mac": [info(id, command: "2.1.311", status: .running, claude: true,
                                            lastOutput: now.addingTimeInterval(-2))]], now: now)
            g.tick(now: now)
        }
        XCTAssertEqual(g.nodes[id]?.state, .working)
    }

    func testClaudeWrappedInBashIsKnownByItsHooks() {
        let g = AgentGraph()
        // tmux says bash and no capture says Claude, but its hooks filled `recent`.
        let id = worker(g, "cl", .working, recent: ["hi"])
        for s in stride(from: 10.0, through: 60, by: 10) {
            let now = t0.addingTimeInterval(s)
            g.keepBusyWorkers(["mac": [info(id, command: "bash", status: .running, lastOutput: t0)]], now: now)
            g.tick(now: now)
        }
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
