import Foundation

// Shared types for linking Claude Code sessions CrossAgent didn't start. Discovery
// fills `ClaudeSession`s for both machines, the transcript feed turns a session's
// .jsonl files into `TranscriptItem`s and an AgentGraph, the views only read.
//
// Facts this is built on (Claude Code 2.1.311, same on the Mac and the PC):
// - ~/.claude/sessions/<pid>.json: one per running session, removed on exit, with pid,
//   sessionId, cwd, startedAt (ms), procStart, name (+ nameSource), status ("idle",
//   "busy", "waiting" + waitingFor "permission prompt" / "input needed"), tmux
//   ("<session>:@w.%p" when inside tmux). procStart catches pid reuse: on macOS it's
//   `ps -o lstart` in UTC, on Linux the starttime field of /proc/<pid>/stat.
// - ~/.claude/projects/<cwd, every non alphanumeric char as "-">/<sessionId>.jsonl.
// - <sessionId>/subagents/agent-<agentId>.jsonl (+ .meta.json with toolUseId,
//   agentType, description, name, finished): one per built-in subagent.

/// Where a session's terminal lives. Decides how it opens, see `ClaudeSession.openMode`.
enum SessionLauncher: String, Codable, Hashable {
    /// A ca-* tmux session (a CrossAgent pane or worker).
    case crossAgent
    /// Any other tmux session.
    case tmux
    case ghostty, terminal, iterm, vscode, cursor, warp
    /// A plain ssh login (the PC, from anywhere).
    case ssh
    case other
    /// Not running any more.
    case ended

    var label: String {
        switch self {
        case .crossAgent: "CrossAgent"
        case .tmux: "tmux"
        case .ghostty: "Ghostty"
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .warp: "Warp"
        case .ssh: "ssh"
        case .other: "a terminal"
        case .ended: "ended"
        }
    }

    /// "Also open in Ghostty", "Also open in Ghostty and ssh". Nil for none.
    static func alsoOpen(_ viewers: [SessionLauncher]) -> String? {
        let names = viewers.map(\.label)
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return "Also open in " + list
    }
}

enum ClaudeSessionStatus: String, Codable, Hashable {
    /// Working on a turn right now.
    case running
    /// Asked the user something (permission prompt, question) and is blocked on it.
    case waiting
    /// Process alive, nothing going on.
    case idle
    /// No process, transcript only.
    case ended
}

/// One Claude Code session on a host, running or recently ended.
struct ClaudeSession: Identifiable, Hashable {
    var hostId: String
    var sessionId: String
    var cwd: String
    /// Nil once ended.
    var pid: Int32?
    var tty: String?
    var launcher: SessionLauncher
    /// The tmux session it runs in, for `.crossAgent` and `.tmux`.
    var tmuxSession: String?
    /// Absolute path of the main transcript on its host.
    var transcriptPath: String
    /// Claude Code's own session name if it has one, else the first prompt, one line.
    var title: String
    var status: ClaudeSessionStatus
    var startedAt: Date
    /// Last transcript write (or process status update).
    var lastActivity: Date
    var subagentCount: Int
    /// Other places attached to its tmux session right now (Ghostty, an ssh login...),
    /// CrossAgent's own clients left out. Same session, same process, no conflict.
    var viewers: [SessionLauncher] = []

    var id: String { "\(hostId):\(sessionId)" }
    var isRunning: Bool { pid != nil }

    /// How a click opens it.
    var openMode: SessionOpenMode {
        if let t = tmuxSession, isRunning { return .attach(tmux: t) }
        return isRunning ? .watch : .transcript
    }
}

enum SessionOpenMode: Hashable {
    /// Already in tmux: attach a terminal tab, as for any session.
    case attach(tmux: String)
    /// Running in a terminal CrossAgent doesn't own: read only Live view.
    case watch
    /// Ended: the transcript, with Continue here.
    case transcript
}

/// One readable line of a transcript, for the Live view.
struct TranscriptItem: Identifiable, Equatable {
    enum Kind: String, Equatable { case user, assistant, thinking, toolUse, toolResult, system }

    /// The entry's uuid, plus a block index when one entry gives several items.
    var id: String
    var kind: Kind
    var text: String
    /// toolUse: the tool name. toolResult: the name of the tool it answers, if known.
    var tool: String?
    /// Set on items that came from a subagent's own transcript.
    var agentId: String?
    var isError: Bool = false
    var at: Date
    /// toolUse: its id. toolResult: the id of the call it answers. Task notifications: the
    /// Agent call they report on.
    var toolUseId: String? = nil
    /// What the line says about a subagent, for the graph. Nil on most items.
    var signal: AgentSignal? = nil
}

/// Subagent lifecycle as a transcript shows it. Claude Code has three flavors:
/// foreground agents (the Agent call returns when they're done), background agents
/// (the call returns at once, a `<task-notification>` comes later) and in-process
/// teammates (the call returns at once, they message the lead and go idle).
enum AgentSignal: Equatable {
    /// An Agent (or Task) tool call. `name` is input.name, else the description.
    case spawn(name: String, prompt: String?)
    /// The Agent call returned but the agent keeps going (background or teammate).
    case launched(agentId: String)
    /// Done: a foreground Agent result, a task notification, or a failed Agent call.
    case finished(agentId: String?, ok: Bool, result: String?)
    /// A teammate messaged the lead.
    case message(from: String, text: String)
    /// A teammate went idle, with its last result if it sent one.
    case teammateIdle(name: String, result: String?)
}
