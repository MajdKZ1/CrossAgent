import Foundation

/// Turns transcript lines into `TranscriptItem`s. One parser per file: it remembers tool
/// names by tool_use id so a tool_result can say which tool it answers.
///
/// Kept: user prompts, assistant text, tool calls and results (results trimmed), thinking
/// when asked and when Claude stored any (usually it's omitted), task notifications,
/// teammate messages and system lines with text. Skipped: attachments, api-request*,
/// queue-operation, last-prompt, tools-used, cost-state, atis-latch, ai-title, isMeta
/// reminders, hook summaries.
struct TranscriptParser {
    /// Set for a subagent's own file. Its items carry it.
    var agentId: String?
    var includeThinking = false
    private(set) var toolNames: [String: String] = [:]

    static let resultLines = 4
    static let resultChars = 400

    init(agentId: String? = nil, includeThinking: Bool = false) {
        self.agentId = agentId
        self.includeThinking = includeThinking
    }

    /// True when the line can hold a readable entry. A byte check, so the many large
    /// attachment and api-request lines never get JSON parsed.
    static func mayMatter(_ line: Data) -> Bool {
        for t in [#""type":"user""#, #""type":"assistant""#, #""type":"system""#] where line.range(of: Data(t.utf8)) != nil {
            return true
        }
        return false
    }

    mutating func parse(_ line: Data) -> [TranscriptItem] {
        guard Self.mayMatter(line),
              let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = d["type"] as? String else { return [] }
        let uuid = d["uuid"] as? String ?? UUID().uuidString
        let at = (d["timestamp"] as? String).flatMap(Self.date) ?? Date()
        switch type {
        case "user": return user(d, uuid, at)
        case "assistant": return assistant(d, uuid, at)
        case "system": return system(d, uuid, at)
        default: return []
        }
    }

    mutating func parse(lines: [Data]) -> [TranscriptItem] {
        lines.flatMap { parse($0) }
    }

    // MARK: Entries

    private func item(_ id: String, _ kind: TranscriptItem.Kind, _ text: String, _ at: Date) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, text: text, tool: nil, agentId: agentId, at: at)
    }

    private mutating func user(_ d: [String: Any], _ uuid: String, _ at: Date) -> [TranscriptItem] {
        if d["isMeta"] as? Bool == true { return [] }
        guard let m = d["message"] as? [String: Any] else { return [] }
        if let s = m["content"] as? String { return userText(s, uuid, at).map { [$0] } ?? [] }
        guard let blocks = m["content"] as? [[String: Any]] else { return [] }
        let tur = d["toolUseResult"] as? [String: Any]
        var out: [TranscriptItem] = []
        for (i, b) in blocks.enumerated() {
            let id = blocks.count == 1 ? uuid : "\(uuid):\(i)"
            switch b["type"] as? String {
            case "text":
                if let s = b["text"] as? String, let it = userText(s, id, at) { out.append(it) }
            case "tool_result":
                let tuid = b["tool_use_id"] as? String
                let isError = b["is_error"] as? Bool ?? false
                let full = Self.resultText(b["content"])
                var it = item(id, .toolResult, Self.trim(full), at)
                it.tool = tuid.flatMap { toolNames[$0] }
                it.toolUseId = tuid
                it.isError = isError
                if it.tool == "Agent" || it.tool == "Task" { it.signal = Self.agentResult(tur, isError: isError, text: full) }
                out.append(it)
            default:
                break
            }
        }
        return out
    }

    /// A user string: a prompt, or one of the tagged things Claude Code injects.
    private func userText(_ raw: String, _ id: String, _ at: Date) -> TranscriptItem? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("<system-reminder>") || s.hasPrefix("<local-command") || s.hasPrefix("Caveat:") { return nil }
        if s.hasPrefix("<task-notification>") {
            let status = Self.tag(s, "status") ?? "completed"
            var it = item(id, .system, Self.tag(s, "summary") ?? "Task \(status)", at)
            it.toolUseId = Self.tag(s, "tool-use-id")
            it.signal = .finished(agentId: Self.tag(s, "task-id"), ok: status == "completed",
                                  result: Self.tag(s, "result"))
            return it
        }
        if s.hasPrefix("<command-name>"), let cmd = Self.tag(s, "command-name") {
            let args = Self.tag(s, "command-args") ?? ""
            return item(id, .user, args.isEmpty ? cmd : cmd + " " + args, at)
        }
        if let r = s.range(of: "<teammate-message ") {
            let from = Self.attr(s[r.lowerBound...], "teammate_id") ?? "teammate"
            let body = Self.tag(s, "teammate-message", open: "<teammate-message ") ?? ""
            // In a teammate's own file this is its brief from the lead.
            if agentId != nil { return item(id, .user, body, at) }
            if let j = body.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
               let kind = j["type"] as? String {
                guard kind == "idle_notification" else { return nil }
                let result = j["result"] as? String
                var it = item(id, .system, "\(from) is idle", at)
                it.signal = .teammateIdle(name: from, result: result)
                return it
            }
            var it = item(id, .system, "\(from): \(body)", at)
            it.signal = .message(from: from, text: body)
            return it
        }
        return item(id, .user, s, at)
    }

    private mutating func assistant(_ d: [String: Any], _ uuid: String, _ at: Date) -> [TranscriptItem] {
        guard let m = d["message"] as? [String: Any], let blocks = m["content"] as? [[String: Any]] else { return [] }
        var out: [TranscriptItem] = []
        for (i, b) in blocks.enumerated() {
            let id = blocks.count == 1 ? uuid : "\(uuid):\(i)"
            switch b["type"] as? String {
            case "text":
                if let s = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    out.append(item(id, .assistant, s, at))
                }
            case "thinking":
                if includeThinking, let s = (b["thinking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    out.append(item(id, .thinking, s, at))
                }
            case "tool_use":
                let name = b["name"] as? String ?? "tool"
                let input = b["input"] as? [String: Any] ?? [:]
                let tuid = b["id"] as? String
                if let tuid { toolNames[tuid] = name }
                var it = item(id, .toolUse, ToolSummary.make(name, input), at)
                it.tool = name
                it.toolUseId = tuid
                if name == "Agent" || name == "Task" {
                    let who = [input["name"], input["description"], input["subagent_type"]]
                        .compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }.first ?? "agent"
                    it.signal = .spawn(name: who, prompt: input["prompt"] as? String)
                }
                out.append(it)
            default:
                break
            }
        }
        return out
    }

    private func system(_ d: [String: Any], _ uuid: String, _ at: Date) -> [TranscriptItem] {
        let sub = d["subtype"] as? String ?? ""
        if ["stop_hook_summary", "turn_duration"].contains(sub) { return [] }
        guard let text = (d["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        var it = item(uuid, .system, text, at)
        it.isError = sub.contains("error")
        return [it]
    }

    // MARK: Helpers

    /// The Agent call's result: still running (background, teammate) or finished.
    private static func agentResult(_ tur: [String: Any]?, isError: Bool, text: String) -> AgentSignal? {
        let aid = tur?["agentId"] as? String
        if isError { return .finished(agentId: aid, ok: false, result: text) }
        switch tur?["status"] as? String {
        case "async_launched", "teammate_spawned":
            return aid.map { .launched(agentId: $0) }
        case "completed":
            return .finished(agentId: aid, ok: true, result: text)
        default:
            return nil
        }
    }

    /// tool_result content: a string or a list of text blocks.
    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }

    /// First few non-empty lines, capped.
    static func trim(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out = lines.prefix(resultLines).joined(separator: "\n")
        if out.count > resultChars { out = String(out.prefix(resultChars - 3)) + "..." }
        else if lines.count > resultLines { out += "\n..." }
        return out
    }

    /// Text inside <name>...</name>, trimmed.
    static func tag(_ s: String, _ name: String, open: String? = nil) -> String? {
        guard let a = s.range(of: open ?? "<\(name)>") else { return nil }
        var start = a.upperBound
        if open != nil {
            // An opening tag with attributes: skip to its ">".
            guard let gt = s[start...].firstIndex(of: ">") else { return nil }
            start = s.index(after: gt)
        }
        let end = s.range(of: "</\(name)>", range: start..<s.endIndex)?.lowerBound ?? s.endIndex
        let t = s[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// name="value" inside an opening tag.
    static func attr(_ s: Substring, _ name: String) -> String? {
        guard let r = s.range(of: name + "=\"") else { return nil }
        guard let end = s[r.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(s[r.upperBound..<end])
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
    private static let isoLock = NSLock()

    static func date(_ s: String) -> Date? {
        isoLock.withLock { iso.date(from: s) ?? isoPlain.date(from: s) }
    }
}
