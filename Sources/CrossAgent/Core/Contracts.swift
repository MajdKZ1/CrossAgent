import Foundation

// Shared types several parts of the app build on: project naming, the event line
// format written by the hooks and by `ca run`, and the agent graph the orchestrator
// canvas and the mascot draw. Keep this file small and boring.

// MARK: - Project naming

enum ProjectSlug {
    /// Lowercase, a-z 0-9 and single dashes, at most 16 chars. Must match `slug()` in
    /// skills/crossagent/scripts/ca so the app and the skill agree on session names.
    static func make(_ name: String) -> String {
        var out = ""
        var lastDash = true
        for ch in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                out.unicodeScalars.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        out = String(out.prefix(16))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "project" : out
    }
}

/// tmux session names. New ones carry the project: `ca-<slug>-<host>-<task>`.
/// Old `ca-<host>-<task>` names (from before projects) are still recognised.
enum CASessionName {
    static func make(slug: String, host: String, task: String) -> String { "ca-\(slug)-\(host)-\(task)" }

    static func orchestrator(slug: String, host: String) -> String { make(slug: slug, host: host, task: "orch") }

    /// Splits a session name into (slug, host, task). `hostIDs` are the configured host ids.
    /// Old names give a nil slug.
    static func parse(_ name: String, hostIDs: [String]) -> (slug: String?, host: String, task: String)? {
        guard name.hasPrefix("ca-") else { return nil }
        let rest = String(name.dropFirst(3))
        // Old form first: ca-<host>-<task>
        for h in hostIDs where rest.hasPrefix(h + "-") {
            let task = String(rest.dropFirst(h.count + 1))
            // ca-pc-1 is old style; ca-myproj-pc-1 is new style with slug "myproj".
            if !task.isEmpty, !hostIDs.contains(where: { task.hasPrefix($0 + "-") }) {
                return (nil, h, task)
            }
        }
        for h in hostIDs {
            if let r = rest.range(of: "-\(h)-") {
                let slug = String(rest[..<r.lowerBound])
                let task = String(rest[r.upperBound...])
                if !slug.isEmpty, !task.isEmpty { return (slug, h, task) }
            }
        }
        return nil
    }
}

// MARK: - Events

/// One line in ~/.crossagent/events/<session>.jsonl on either machine. Written by the
/// CrossAgent Claude Code hook (Claude events) or by `ca run` (Worker events).
/// Every field but `ts` and `ev` is optional; unknown fields are ignored.
struct AgentEvent: Codable, Equatable {
    var ts: Double                // unix seconds
    var ev: String                // hook_event_name, or WorkerStart / WorkerStop
    var host: String?             // machine that wrote it: "mac" or "pc"
    var sid: String?              // Claude session_id, or the tmux session for workers
    var cwd: String?
    var role: String?             // CROSSAGENT_ROLE: "orchestrator" | "worker"
    var project: String?          // CROSSAGENT_PROJECT slug
    var node: String?             // CROSSAGENT_NODE: worker task name
    var aid: String?              // agent_id (built-in subagent)
    var atype: String?            // agent_type
    var name: String?             // Agent tool input.name, or worker name
    var tool: String?             // tool_name
    var tuid: String?             // tool_use_id
    var sum: String?              // short one line summary, <= 160 chars
    var prompt: String?           // Agent tool prompt, <= 600 chars
    var to: String?               // SendMessage target
    var bg: [String]?             // Stop: ids of still running background subagents
    var msg: String?              // last assistant message, <= 300 chars
    var err: String?              // failure text
    var tmux: String?             // worker tmux session
    var rc: Int?                  // worker exit code
    var turn: Int?                // remote worker: 1 for the brief, 2+ for follow-ups
    var csid: String?             // remote worker: its headless Claude session id
    var path: String?             // remote worker: brief.md (RemoteStart) or result.md (RemoteStop), absolute on `host`
    var req: String?              // permission request id (PermissionAsk / PermissionAnswer)
}

// Remote worker events, written on the machine the worker runs on by `ca remote`
// (RemoteStart/Stop), its stream formatter (RemoteActivity) and its permission tool
// (PermissionAsk/Answer). All carry role "remote", node = the worker's role, tmux = its
// session ca-<slug>-<host>-<role>, sid = the same session (it names the event file).
//   RemoteStart       turn, path (brief.md), cwd, sum (goal), csid on follow-ups
//   RemoteActivity    tool (absent for plain text), sum
//   RemoteStop        turn, rc, csid, path (result.md), sum (first line of the summary)
//   PermissionAsk     req, tool, sum ("Needs permission: Running x"), prompt (detail)
//   PermissionAnswer  req, msg ("allow", "deny" or "timeout")
// The app answers a PermissionAsk by writing "allow" or "deny" to
// ~/.crossagent/approvals/<req>.answer on that host (same as `ca remote answer`).

// MARK: - Agent graph

enum AgentKind: String, Codable {
    case orchestrator
    /// Claude Code's built-in Agent/Task subagent. No terminal of its own.
    case subagent
    /// `ca run` worker in its own tmux session on the Mac or the PC.
    case worker
}

enum AgentState: Equatable, Codable {
    case thinking
    case working
    case needsInput(String)
    case waiting([String])
    case idle
    case done
    case error(String)
}

/// Which way data is moving on a node's cable, and when it last moved.
enum CableFlow: String, Codable { case none, toNode, toOrchestrator }

struct AgentNode: Identifiable, Equatable, Codable {
    var id: String                // agent_id, worker tmux session, or "orchestrator"
    var name: String              // shown above the node
    var kind: AgentKind
    var hostId: String
    var state: AgentState
    var activity: String          // one line, like "Running swift build"
    var tmuxSession: String?      // workers and the orchestrator
    var prompt: String?           // subagents: what they were asked
    var recent: [String] = []     // last few tool calls and outputs, newest last
    var startedAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var flow: CableFlow = .none
    var flowAt: Date?
    /// While `needsInput`: the state it interrupted (a pending `ca wait`), restored once answered.
    var resumeState: AgentState? = nil
    /// Set when this node is (or proxies) a remote worker started with `ca remote`.
    var remote: RemoteInfo? = nil
}

/// A headless Claude Code worker on another machine. The Mac side `pc-worker` subagent
/// and the PC side worker are one node: the subagent's node carries this once its
/// `ca remote` call is seen.
struct RemoteInfo: Equatable, Codable {
    var host: String              // where the worker runs
    var role: String
    var tmuxSession: String       // ca-<slug>-<host>-<role>, on `host`
    var claudeSession: String?    // headless session id, the same for every follow-up
    var turn: Int = 0
    var briefPath: String?        // absolute on `host`
    var resultPath: String?       // absolute on `host`
    var permission: PermissionAsk? = nil
}

struct PermissionAsk: Equatable, Codable {
    var id: String                // request id, names ~/.crossagent/approvals/<id>.answer
    var host: String
    var text: String              // "Needs permission: Running npm test"
    var detail: String?
    var at: Date
}

/// The live graph for one project. The orchestrator is always `nodes[orchestratorID]`.
/// Events go in through `apply(_:)` (Core/Events), the canvas and the mascot read it.
@MainActor
final class AgentGraph: ObservableObject {
    static let orchestratorID = "orchestrator"

    @Published var nodes: [String: AgentNode] = [:]
    /// Finished nodes kept on the canvas until the user clears them, oldest first.
    @Published var finished: [String] = []

    var orchestrator: AgentNode? { nodes[Self.orchestratorID] }
    var others: [AgentNode] { nodes.values.filter { $0.kind != .orchestrator }.sorted { $0.startedAt < $1.startedAt } }

    init(orchestratorHost: String = "mac", session: String? = nil) {
        let now = Date()
        nodes[Self.orchestratorID] = AgentNode(id: Self.orchestratorID, name: "orchestrator", kind: .orchestrator,
                                               hostId: orchestratorHost, state: .idle, activity: "Idle",
                                               tmuxSession: session, startedAt: now, updatedAt: now)
    }

    func clearFinished() {
        for id in finished { nodes[id] = nil }
        finished = []
    }
}
