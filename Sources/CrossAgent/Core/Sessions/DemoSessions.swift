import Foundation

/// What the session list and the Live view show while DemoMode is on: a fixed, made up
/// list and short scripted conversations. Nothing under ~/.claude is read, no ssh.
enum DemoSessions {
    static let router = "demo-0001-refactor-router"
    static let flaky = "demo-0002-fix-flaky-tests"
    static let settings = "demo-0003-settings-screen"
    static let docs = "demo-0004-api-docs"

    /// Where the demo project sits on each machine.
    static func macFolder(slug: String = "demo") -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/\(slug)").path
    }
    static func pcFolder(slug: String = "demo") -> String { "/home/demo/Projects/\(slug)" }

    /// Two running (Mac working, PC waiting on a permission) and two ended.
    static func list(mac: String, pc: String, now: Date = Date()) -> [ClaudeSession] {
        func s(_ host: String, _ id: String, _ title: String, _ status: ClaudeSessionStatus, _ launcher: SessionLauncher,
               started: TimeInterval, last: TimeInterval, agents: Int) -> ClaudeSession {
            let cwd = host == mac ? macFolder() : pcFolder()
            return ClaudeSession(hostId: host, sessionId: id, cwd: cwd, pid: status == .ended ? nil : 40000 + Int32(agents),
                                 tty: nil, launcher: launcher, tmuxSession: nil,
                                 transcriptPath: cwd + "/.demo/\(id).jsonl", title: title, status: status,
                                 startedAt: now.addingTimeInterval(-started), lastActivity: now.addingTimeInterval(-last),
                                 subagentCount: agents)
        }
        return [
            s(mac, router, "Refactor the router", .running, .ghostty, started: 1260, last: 4, agents: 2),
            s(pc, flaky, "Fix flaky tests", .waiting, .ssh, started: 2400, last: 35, agents: 1),
            s(mac, settings, "Add a settings screen", .ended, .ended, started: 86400 + 5400, last: 86400 + 1800, agents: 3),
            s(pc, docs, "Update the API docs", .ended, .ended, started: 2 * 86400 + 3600, last: 2 * 86400, agents: 0),
        ]
    }

    /// One conversation per demo session, oldest first, `step` seconds apart from `start`.
    static func items(sessionId: String, start: Date = Date(), step: TimeInterval = 0.7) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        func add(_ kind: TranscriptItem.Kind, _ text: String, tool: String? = nil, agent: String? = nil,
                 use: String? = nil, signal: AgentSignal? = nil) {
            let at = start.addingTimeInterval(Double(out.count) * step)
            out.append(TranscriptItem(id: "\(sessionId)-\(out.count)", kind: kind, text: text, tool: tool, agentId: agent,
                                      at: at, toolUseId: use, signal: signal))
        }
        switch sessionId {
        case router:
            add(.user, "The router does a linear scan for every request. Make matching faster and keep the API.")
            add(.assistant, "I'll map the routes first, then swap the scan for a trie.")
            add(.toolUse, "Reading Sources/App/Router.swift", tool: "Read", use: "tu-r1")
            add(.toolResult, "214 lines", tool: "Read", use: "tu-r1")
            add(.toolUse, "explore: Map the router", tool: "Agent", use: "tu-agent1",
                signal: .spawn(name: "explore", prompt: "List every route in Sources/App/Router.swift and how it is matched."))
            add(.toolUse, "Reading docs/api.md", tool: "Read", agent: "demo-agent-explore")
            add(.toolUse, "Searching for func match", tool: "Grep", agent: "demo-agent-explore")
            add(.toolResult, "Mapped all 14 routes. Two did a linear scan.", tool: "Agent", use: "tu-agent1",
                signal: .finished(agentId: "demo-agent-explore", ok: true, result: "Mapped all 14 routes. Two did a linear scan."))
            add(.toolUse, "Editing Sources/App/Router.swift", tool: "Edit", use: "tu-e1")
            add(.toolUse, "Running swift test --filter RouterTests", tool: "Bash", use: "tu-b1")
            add(.toolResult, "Executed 38 tests, with 0 failures", tool: "Bash", use: "tu-b1")
            add(.assistant, "Matching goes through a trie now. Lookups are about 3x faster and all router tests pass.")
        case flaky:
            add(.user, "TrieTests fails about one run in ten on the PC. Find out why and fix it.")
            add(.assistant, "Let me run it in a loop to catch it.")
            add(.toolUse, "Running swift test --filter TrieTests --repeat 20", tool: "Bash", use: "tu-f1")
            add(.toolResult, "2 of 20 runs failed: testConcurrentInsert", tool: "Bash", use: "tu-f1")
            add(.assistant, "It's a race in the test's shared fixture. I'll give each test its own trie.")
            add(.toolUse, "Editing Tests/RouterTests/TrieTests.swift", tool: "Edit", use: "tu-f2")
            add(.toolUse, "Running swift test --filter TrieTests --repeat 50", tool: "Bash", use: "tu-f3")
        case settings:
            add(.user, "Add a settings screen that lists the hosts.")
            add(.toolUse, "Editing Sources/App/SettingsView.swift", tool: "Edit", use: "tu-s1")
            add(.assistant, "The settings screen lists hosts with add, edit and reset.")
        case docs:
            add(.user, "Update docs/api.md for the new routes.")
            add(.toolUse, "Editing docs/api.md", tool: "Edit", use: "tu-d1")
            add(.assistant, "docs/api.md covers all 14 routes now.")
        default:
            add(.system, "Nothing to show in the demo")
        }
        return out
    }
}

/// Hands a demo conversation to the feed: ended ones at once, running ones a line at a time.
final class DemoFeedSource: FeedSource, @unchecked Sendable {
    private let sessionId: String
    private let live: Bool
    private let onBatch: @MainActor (FeedBatch) -> Void
    private var timer: Timer?
    private var sent = 0

    init(sessionId: String, live: Bool, onBatch: @escaping @MainActor (FeedBatch) -> Void) {
        self.sessionId = sessionId
        self.live = live
        self.onBatch = onBatch
    }

    func start() {
        guard timer == nil, sent == 0 || live else { return }
        // In the past, so lines trickling in later (stamped now) stay in order.
        let all = DemoSessions.items(sessionId: sessionId, start: Date().addingTimeInterval(-600))
        // Running ones: the first few lines at once, the rest trickling in.
        let first = live ? min(4, all.count) : all.count
        deliver(Array(all[sent..<max(sent, first)]))
        sent = max(sent, first)
        guard live, sent < all.count else { return }
        let t = Timer(timeInterval: 0.9, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.sent < all.count else { t.invalidate(); return }
                var item = all[self.sent]
                item.at = Date()
                self.sent += 1
                self.deliver([item])
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func shutdown(timeout: TimeInterval) { stop() }

    private func deliver(_ items: [TranscriptItem]) {
        guard !items.isEmpty else { return }
        let batch = FeedBatch(items: items)
        let send = onBatch
        Task { @MainActor in send(batch) }
    }
}
