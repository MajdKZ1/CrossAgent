import Foundation

// Shared types for linking Claude Code sessions CrossAgent didn't start. Discovery
// fills `ClaudeSession`s for both machines, the transcript feed turns a session's
// .jsonl files into `TranscriptItem`s and an AgentGraph, the views only read.
//
// Facts this is built on (Claude Code 2.1.311, same on the Mac and the PC):
// - ~/.claude/sessions/<pid>.json: one per running session, with pid, sessionId, cwd,
//   startedAt (ms), procStart (to catch pid reuse), name, status, updatedAt.
// - ~/.claude/projects/<cwd with "/" and "." as "-">/<sessionId>.jsonl: the transcript.
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
}
