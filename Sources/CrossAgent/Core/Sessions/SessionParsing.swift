import Foundation

// Pure parsing for session discovery: the session json, paths, process chains, subagent
// metas and transcript heads. No IO here beyond what the caller hands in.

/// ~/.claude/sessions/<pid>.json. Unknown fields are ignored.
struct SessionFile: Codable, Equatable {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var startedAt: Double?        // ms
    var procStart: String?
    var name: String?
    var nameSource: String?       // "derived" when Claude made it up from the folder
    var status: String?           // "idle", "busy", "waiting"
    var waitingFor: String?       // "permission prompt", "input needed"
    var tmux: String?             // "<session>:@<window>.%<pane>"
    var updatedAt: Double?        // ms
    var statusUpdatedAt: Double?  // ms
    var entrypoint: String?       // "cli", "sdk-cli" (claude -p)

    static func parse(_ data: Data) -> SessionFile? {
        try? JSONDecoder().decode(SessionFile.self, from: data)
    }

    /// The tmux session name from the `tmux` field.
    var tmuxSession: String? {
        guard let t = tmux, let name = t.split(separator: ":").first, !name.isEmpty else { return nil }
        return String(name)
    }

    /// The user named it (not Claude's folder based default).
    var userName: String? {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty, nameSource != "derived" else { return nil }
        return n
    }

    var sessionStatus: ClaudeSessionStatus {
        switch status {
        case "busy": .running
        case "waiting": .waiting
        default: .idle
        }
    }
}

enum ClaudePaths {
    /// Project folder name for a cwd: every char but a-z A-Z 0-9 becomes "-".
    static func projectSlug(cwd: String) -> String {
        String(cwd.unicodeScalars.map { s -> Character in
            s.isASCII && (CharacterSet.alphanumerics.contains(s)) ? Character(s) : "-"
        })
    }

    static func transcript(root: String, cwd: String, sessionId: String) -> String {
        "\(root)/projects/\(projectSlug(cwd: cwd))/\(sessionId).jsonl"
    }

    /// <projectdir>/<sessionId>/subagents for a transcript path.
    static func subagentsDir(transcript: String) -> String {
        String(transcript.dropLast(".jsonl".count)) + "/subagents"
    }

    /// "agent-<id>.jsonl" or "agent-<id>.meta.json" to "<id>".
    static func agentId(fileName: String) -> String? {
        guard fileName.hasPrefix("agent-") else { return nil }
        var s = String(fileName.dropFirst(6))
        for ext in [".meta.json", ".jsonl"] where s.hasSuffix(ext) {
            s.removeLast(ext.count)
            return s.isEmpty ? nil : s
        }
        return nil
    }
}

/// One row of `ps -axo pid=,ppid=,tty=,lstart=,comm=` (run with TZ=UTC).
struct ProcInfo: Equatable {
    var pid: Int32
    var ppid: Int32
    var tty: String?
    /// "Tue Oct 27 07:18:27 2026", single spaced.
    var lstart: String
    var comm: String

    static func parsePS(_ out: String) -> [Int32: ProcInfo] {
        var table: [Int32: ProcInfo] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let w = line.split(separator: " ", omittingEmptySubsequences: true)
            guard w.count >= 9, let pid = Int32(w[0]), let ppid = Int32(w[1]) else { continue }
            let tty = w[2] == "??" || w[2] == "?" ? nil : String(w[2])
            table[pid] = ProcInfo(pid: pid, ppid: ppid, tty: tty, lstart: w[3...7].joined(separator: " "),
                                  comm: w[8...].joined(separator: " "))
        }
        return table
    }

    /// Command names from the parent up to launchd, nearest first.
    static func ancestors(of pid: Int32, in table: [Int32: ProcInfo]) -> [String] {
        var out: [String] = []
        var p = table[pid]?.ppid ?? 0
        while p > 1, let info = table[p], out.count < 32 {
            out.append(info.comm)
            p = info.ppid
        }
        return out
    }

    /// Same process as the session file says (pid not reused). A missing procStart passes.
    static func sameStart(_ procStart: String?, lstart: String) -> Bool {
        guard let ps = procStart, !ps.isEmpty else { return true }
        let norm = { (s: String) in s.split(separator: " ").joined(separator: " ") }
        return norm(ps) == norm(lstart)
    }
}

enum LauncherClassifier {
    /// Which terminal a session lives in, from its ancestors' command names (nearest
    /// first) and the tmux session from the session file.
    static func classify(chain: [String], tmuxSession: String?) -> SessionLauncher {
        if let t = tmuxSession { return t.hasPrefix("ca-") ? .crossAgent : .tmux }
        for comm in chain {
            let c = comm.lowercased()
            let base = c.split(separator: "/").last.map(String.init) ?? c
            if base.hasPrefix("tmux") { return .tmux }
            if base == "sshd" || base.hasPrefix("sshd-") || base.hasPrefix("sshd:") { return .ssh }
            if c.contains("crossagent") { return .crossAgent }
            if c.contains("ghostty") { return .ghostty }
            if c.contains("terminal.app") { return .terminal }
            if c.contains("iterm") { return .iterm }
            if c.contains("visual studio code") || base.hasPrefix("code helper") || base == "code" { return .vscode }
            if c.contains("cursor.app") || base.hasPrefix("cursor") { return .cursor }
            if c.contains("warp.app") { return .warp }
        }
        return .other
    }

    /// Where else a tmux session is open, from its clients: one launcher each, deduped,
    /// in order. CrossAgent's own clients are left out, by their CROSSAGENT_CLIENT mark
    /// (the PC) or a CrossAgent ancestor (the Mac).
    static func viewers(_ clients: [RawClient]) -> [SessionLauncher] {
        var out: [SessionLauncher] = []
        for c in clients where c.ca != true {
            let l = classify(chain: c.chain, tmuxSession: nil)
            if l != .crossAgent, l != .ended, !out.contains(l) { out.append(l) }
        }
        return out
    }
}

/// <sessionId>/subagents/agent-<agentId>.meta.json. Background and foreground agents
/// carry toolUseId and finished, in-process teammates carry neither.
struct SubagentMeta: Codable, Equatable {
    var agentType: String?
    var description: String?
    var name: String?
    var toolUseId: String?
    var spawnDepth: Int?
    var requestShape: String?     // "background", "foreground"
    var taskKind: String?         // "in_process_teammate"
    var finished: Bool?

    static func parse(_ data: Data) -> SubagentMeta? {
        try? JSONDecoder().decode(SubagentMeta.self, from: data)
    }

    var displayName: String { name ?? description ?? agentType ?? "agent" }
}

/// What the start of a transcript says: enough for a title and the cwd of an ended session.
struct TranscriptHead: Codable, Equatable {
    var cwd: String?
    var aiTitle: String?
    var prompt: String?
    /// First entry timestamp, unix seconds.
    var started: Double?

    /// Bytes read from the head. Must match `maxHead` in the PC discovery script.
    static let maxBytes = 512 * 1024

    /// Scans complete lines of `data` (the first `maxBytes` of a transcript).
    static func scan(_ data: Data) -> TranscriptHead {
        var head = TranscriptHead()
        for line in data.split(separator: 0x0A) {
            // Cheap byte checks first: most head lines are big attachments.
            let isTitle = line.range(of: Data(#""type":"ai-title""#.utf8)) != nil
            let isUser = line.range(of: Data(#""type":"user""#.utf8)) != nil
            guard isTitle || isUser || head.cwd == nil || head.started == nil else { continue }
            guard let d = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if head.cwd == nil, let c = d["cwd"] as? String { head.cwd = c }
            if head.started == nil, let ts = d["timestamp"] as? String, let t = TranscriptParser.date(ts) {
                head.started = t.timeIntervalSince1970
            }
            if d["type"] as? String == "ai-title", let t = d["aiTitle"] as? String, !t.isEmpty { head.aiTitle = t }
            if head.prompt == nil, d["type"] as? String == "user", let p = Self.prompt(d) { head.prompt = p }
        }
        return head
    }

    /// The text of a real typed prompt, nil for tool results, reminders and notifications.
    static func prompt(_ d: [String: Any]) -> String? {
        if d["isMeta"] as? Bool == true || d["isSidechain"] as? Bool == true { return nil }
        guard let m = d["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = m["content"] as? String { text = s }
        else if let blocks = m["content"] as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.hasPrefix("<"), !t.hasPrefix("Caveat:") else { return nil }
        return t
    }
}

enum SessionTitle {
    /// A name the user gave, else Claude's own title, else the first prompt, else the
    /// folder based name. One line, short.
    static func make(userName: String?, aiTitle: String?, prompt: String?, derivedName: String?, cwd: String) -> String {
        for c in [userName, aiTitle, prompt, derivedName] {
            if let c {
                let s = AgentGraph.oneLine(c)
                if !s.isEmpty { return s.count > 80 ? String(s.prefix(77)) + "..." : s }
            }
        }
        let folder = cwd.split(separator: "/").last.map(String.init) ?? cwd
        return folder.isEmpty ? "Untitled" : folder
    }
}

/// One line for a tool call, like "Running swift build". Same wording as tool_summary
/// in crossagent-hook.py, so hooks and transcripts read alike on the canvas.
enum ToolSummary {
    static func make(_ tool: String, _ input: [String: Any]) -> String {
        func s(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func base(_ p: String?) -> String {
            let t = (p ?? "").hasSuffix("/") ? String((p ?? "").dropLast()) : (p ?? "")
            return t.split(separator: "/").last.map(String.init) ?? t
        }
        switch tool {
        case "Bash":
            let first = (s("command") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).first.map(String.init)
            return "Running " + (first ?? "a command")
        case "Edit", "MultiEdit": return "Editing " + base(s("file_path"))
        case "Write": return "Writing " + base(s("file_path"))
        case "Read": return "Reading " + base(s("file_path"))
        case "NotebookEdit": return "Editing " + base(s("notebook_path"))
        case "Grep": return "Searching for " + (s("pattern") ?? "")
        case "Glob": return "Finding " + (s("pattern") ?? "files")
        case "WebFetch":
            let url = s("url") ?? ""
            let host = url.components(separatedBy: "://").last?.split(separator: "/").first.map(String.init) ?? ""
            return "Fetching " + (host.isEmpty ? "a page" : host)
        case "WebSearch": return "Searching the web: " + (s("query") ?? "")
        case "Agent", "Task":
            let who = s("name") ?? s("subagent_type") ?? "agent"
            return "Starting " + who + (s("description").map { ": " + $0 } ?? "")
        case "SendMessage":
            let to = s("to") ?? s("recipient") ?? "someone"
            let what = s("summary") ?? s("message")
            return "Messaging " + to + (what.map { ": " + $0 } ?? "")
        case "SubagentHandback": return "Reporting back"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updating the todo list"
        case "AskUserQuestion": return "Asking a question"
        default:
            if tool.hasPrefix("mcp__") { return "Using " + (tool.components(separatedBy: "__").last ?? tool) }
            return "Using " + tool
        }
    }
}
