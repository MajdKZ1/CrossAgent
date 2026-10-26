import Foundation

enum SessionStatus: String, Hashable {
    case running, idle, waitingForInput, exited
}

/// One `ca-*` tmux session on a host, as seen by the last poll.
struct TmuxSessionInfo: Identifiable, Hashable {
    var hostId: String
    var name: String
    var createdAt: Date
    var lastActivity: Date
    var currentCommand: String
    var paneDead: Bool
    var attachedClients: Int
    var cols: Int
    var rows: Int
    /// Visible screen with ANSI escapes (`capture-pane -p -e`). Empty until the first fast poll.
    var capture: String
    var status: SessionStatus
    var isClaude: Bool

    var id: String { "\(hostId)/\(name)" }
    var runningFor: TimeInterval { Date().timeIntervalSince(createdAt) }
}

/// A Claude Code process on a host that is not inside a `ca-*` tmux session.
struct ExternalClaude: Identifiable, Hashable {
    var hostId: String
    var pid: Int
    var elapsed: TimeInterval
    var cwd: String?

    var id: String { "\(hostId)/\(pid)" }
}

// MARK: - Poll script and parser (pure)

enum TmuxPoll {
    /// Raw fields of one `list-panes` line.
    struct Pane: Equatable {
        var session: String
        var active: Bool
        var pid: Int
        var dead: Bool
        var created: TimeInterval
        var activity: TimeInterval
        var attached: Int
        var cols: Int
        var rows: Int
        var command: String
    }

    struct Proc: Equatable {
        var pid: Int
        var ppid: Int
        var elapsed: TimeInterval
        var comm: String
    }

    struct Output: Equatable {
        var hostNow: TimeInterval?
        var panes: [Pane] = []
        var captures: [String: String] = [:]
        var procs: [Proc] = []
        var cwds: [Int: String] = [:]
        /// False when the end marker is missing (output cut off).
        var complete = false
    }

    static let paneFormat = [
        "#{session_name}", "#{&&:#{window_active},#{pane_active}}", "#{pane_pid}", "#{pane_dead}",
        "#{session_created}", "#{session_activity}", "#{window_activity}", "#{session_attached}",
        "#{pane_width}", "#{pane_height}", "#{pane_current_command}",
    ].joined(separator: "\t")

    /// One round trip per poll. Works in sh and zsh. `marker` separates sections and must not
    /// appear in pane output, so callers pass a fresh random one.
    static func script(marker m: String, captures: Bool, processes: Bool) -> String {
        var s = """
        printf '%s now %s\\n' '\(m)' "$(date +%s)"
        printf '%s panes\\n' '\(m)'
        tmux list-panes -a -F '\(paneFormat)' 2>/dev/null | grep '^ca-'

        """
        if captures {
            s += """
            tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^ca-' | while IFS= read -r s; do
              printf '%s cap %s\\n' '\(m)' "$s"
              tmux capture-pane -p -e -t "=$s:" 2>/dev/null
            done

            """
        }
        if processes {
            s += """
            printf '%s ps\\n' '\(m)'
            ps -A -o pid=,ppid=,etime=,comm= 2>/dev/null
            printf '%s cwd\\n' '\(m)'
            cp=$(ps -A -o pid=,comm= 2>/dev/null | awk '{n=$2; sub(/.*\\//,"",n); if (n=="claude" || n ~ /^[0-9]+\\.[0-9]+\\.[0-9]+$/) print $1}')
            if [ -n "$cp" ]; then
              if [ -d /proc/self ]; then
                printf '%s\\n' "$cp" | while IFS= read -r p; do printf 'p%s\\nn%s\\n' "$p" "$(readlink /proc/$p/cwd 2>/dev/null)"; done
              else
                lsof -a -d cwd -Fpn -p "$(printf '%s' "$cp" | tr '\\n' ',')" 2>/dev/null
              fi
            fi

            """
        }
        s += "printf '%s end\\n' '\(m)'\n"
        return s
    }

    static func parse(_ text: String, marker: String) -> Output {
        var out = Output()
        enum Section { case none, panes, cap(String), ps, cwd }
        var section = Section.none
        var capLines: [Substring] = []
        var cwdPid: Int?

        func flushCapture() {
            if case .cap(let name) = section {
                out.captures[name] = capLines.joined(separator: "\n")
            }
            capLines = []
        }

        let prefix = marker + " "
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(prefix) {
                flushCapture()
                let rest = line.dropFirst(prefix.count)
                let parts = rest.split(separator: " ", maxSplits: 1)
                switch parts.first.map(String.init) ?? "" {
                case "now": out.hostNow = parts.count > 1 ? TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)) : nil; section = .none
                case "panes": section = .panes
                case "cap": section = .cap(parts.count > 1 ? String(parts[1]) : "")
                case "ps": section = .ps
                case "cwd": section = .cwd
                case "end": out.complete = true; section = .none
                default: section = .none
                }
                continue
            }
            switch section {
            case .none: break
            case .panes: if let p = parsePane(line) { out.panes.append(p) }
            case .cap: capLines.append(line)
            case .ps: if let p = parseProc(line) { out.procs.append(p) }
            case .cwd:
                if line.hasPrefix("p") { cwdPid = Int(line.dropFirst()) }
                else if line.hasPrefix("n"), let pid = cwdPid, line.count > 1 { out.cwds[pid] = String(line.dropFirst()) }
            }
        }
        flushCapture()
        return out
    }

    static func parsePane(_ line: Substring) -> Pane? {
        let f = line.split(separator: "\t", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 11, f[0].hasPrefix("ca-"), let pid = Int(f[2]),
              let created = TimeInterval(f[4]) else { return nil }
        let activity = max(TimeInterval(f[5]) ?? 0, TimeInterval(f[6]) ?? 0, created)
        return Pane(session: f[0], active: f[1] == "1", pid: pid, dead: f[3] == "1",
                    created: created, activity: activity, attached: Int(f[7]) ?? 0,
                    cols: Int(f[8]) ?? 0, rows: Int(f[9]) ?? 0, command: f[10])
    }

    static func parseProc(_ line: Substring) -> Proc? {
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard f.count == 4, let pid = Int(f[0]), let ppid = Int(f[1]),
              let et = parseElapsed(String(f[2])) else { return nil }
        return Proc(pid: pid, ppid: ppid, elapsed: et, comm: String(f[3]).trimmingCharacters(in: .whitespaces))
    }

    /// `ps` etime: [[dd-]hh:]mm:ss
    static func parseElapsed(_ s: String) -> TimeInterval? {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + $1! } + days * 86400
    }

    /// One info per session (the active pane wins). `clockOffset` = local now minus host now,
    /// so durations stay right when the host clock is off.
    static func sessions(hostId: String, output: Output, previous: [String: TmuxSessionInfo],
                         clockOffset: TimeInterval, withCaptures: Bool, now: Date = Date()) -> [TmuxSessionInfo] {
        var bySession: [String: Pane] = [:]
        for p in output.panes where bySession[p.session] == nil || p.active { bySession[p.session] = p }
        return bySession.values.map { p in
            let prev = previous[p.session]
            let created = Date(timeIntervalSince1970: p.created + clockOffset)
            let activity = Date(timeIntervalSince1970: p.activity + clockOffset)
            let capture = withCaptures ? (output.captures[p.session] ?? "") : (prev?.capture ?? "")
            let status: SessionStatus
            if withCaptures {
                status = SessionDetector.status(previous: prev?.capture, current: capture,
                                                command: p.command, paneDead: p.dead)
            } else {
                status = SessionDetector.statusWithoutCapture(previous: prev, lastActivity: activity,
                                                              paneDead: p.dead, now: now)
            }
            return TmuxSessionInfo(hostId: hostId, name: p.session, createdAt: created, lastActivity: activity,
                                   currentCommand: p.command, paneDead: p.dead, attachedClients: p.attached,
                                   cols: p.cols, rows: p.rows, capture: capture, status: status,
                                   isClaude: SessionDetector.isClaude(command: p.command, capture: capture))
        }
        .sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    /// Top level Claude processes that are not descendants of a `ca-*` pane.
    static func externalClaudes(hostId: String, output: Output) -> [ExternalClaude] {
        let parent = Dictionary(output.procs.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        let claudePids = Set(output.procs.filter { SessionDetector.isClaudeCodeProcess($0.comm) }.map(\.pid))
        let panePids = Set(output.panes.map(\.pid))
        return output.procs.compactMap { p in
            guard claudePids.contains(p.pid) else { return nil }
            var cur = p.ppid
            var hops = 0
            while cur > 1, hops < 64 {
                if panePids.contains(cur) || claudePids.contains(cur) { return nil }
                cur = parent[cur] ?? 0
                hops += 1
            }
            if panePids.contains(p.pid) { return nil }
            return ExternalClaude(hostId: hostId, pid: p.pid, elapsed: p.elapsed, cwd: output.cwds[p.pid])
        }
        .sorted { $0.pid < $1.pid }
    }
}

// MARK: - Status heuristic (pure)

/// Status heuristic, checked in this order:
/// 1. exited: tmux reports the pane dead (only with remain-on-exit; otherwise the session vanishes).
/// 2. waitingForInput: Claude Code shows a permission / question / trust dialog near the bottom
///    ("Do you want to proceed?", "Esc to cancel", "Enter to confirm", "Enter to select", a "❯ 1." menu).
/// 3. running: Claude shows its spinner line, e.g. "✻ Infusing… (11s · still thinking ...)" or
///    "· Nucleating…" (spinner glyph, a word ending in "…"), or the older "esc to interrupt".
///    For non Claude, non shell programs: the screen changed since the last poll.
///    Claude is not judged by screen changes because its idle footer redraws on its own.
///    Shells too: a shell running a loop still has zsh as its pane command.
/// 4. idle otherwise (a shell sitting at its prompt does not change).
enum SessionDetector {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "-zsh", "-bash", "login"]

    static let waitingMarkers = [
        "Do you want to proceed?", "Do you want to make this edit", "Do you want to create",
        "Esc to cancel", "Enter to confirm", "Enter to select", "Would you like to proceed",
    ]
    static let spinnerGlyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "*", "✺", "∗"]

    static func status(previous: String?, current: String, command: String, paneDead: Bool) -> SessionStatus {
        if paneDead { return .exited }
        let tail = bottomLines(stripANSI(current), count: 20)
        let claude = isClaude(command: command, capture: current)
        if claude || !shells.contains(command) {
            if tail.contains(where: { line in waitingMarkers.contains { line.contains($0) } })
                || tail.contains(where: isNumberedChoice) {
                return .waitingForInput
            }
            if tail.contains(where: isBusyLine) { return .running }
        }
        // A program, or a shell running a loop or a builtin: the screen moving means busy.
        if !claude, let previous, previous != current { return .running }
        return .idle
    }

    /// Slow polls have no capture: keep the last status while nothing happened, otherwise
    /// call it running if tmux saw output in the last few seconds.
    static func statusWithoutCapture(previous: TmuxSessionInfo?, lastActivity: Date, paneDead: Bool,
                                     now: Date = Date()) -> SessionStatus {
        if paneDead { return .exited }
        if let previous, previous.lastActivity == lastActivity, previous.status != .exited { return previous.status }
        return now.timeIntervalSince(lastActivity) < 5 ? .running : .idle
    }

    static func isClaude(command: String, capture: String) -> Bool {
        if command.lowercased().contains("claude") || isClaudeCodeProcess(command) { return true }
        // npm installs run as node; check the screen for Claude Code's TUI.
        let text = stripANSI(capture)
        return text.contains("Claude Code v") || text.contains("(shift+tab to cycle)")
            || text.contains("? for shortcuts") || text.contains("⏸ manual mode on")
    }

    /// tmux reports claude as "claude" (Linux) or as its version, e.g. "2.1.310" (macOS).
    /// Exact match, so the Claude desktop app ("Claude") is not counted.
    static func isClaudeCodeProcess(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        if base == "claude" { return true }
        return base.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    static func isBusyLine(_ line: Substring) -> Bool {
        if line.contains("esc to interrupt") { return true }
        let t = line.drop { $0 == " " }
        guard let g = t.first, spinnerGlyphs.contains(g) else { return false }
        let rest = t.dropFirst()
        guard rest.first == " " else { return false }
        // First word ends with an ellipsis: "Infusing…", "Bunning…". "✻ Worked for 3s" is the done line.
        let word = rest.drop { $0 == " " }.prefix { $0 != " " }
        return word.count > 1 && word.hasSuffix("…")
    }

    static func isNumberedChoice(_ line: Substring) -> Bool {
        line.range(of: #"^\s*❯\s*1\.\s"#, options: .regularExpression) != nil
    }

    static func bottomLines(_ s: String, count: Int) -> [Substring] {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.allSatisfy(\.isWhitespace) }
        return Array(lines.suffix(count))
    }

    /// Removes CSI, OSC (hyperlinks, titles) and other two byte escape sequences.
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(
            of: #"\x1B(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)|[@-Z\\-_])"#,
            with: "", options: .regularExpression)
    }
}

// MARK: - Monitor

@MainActor
final class TmuxMonitor: ObservableObject {
    @Published private(set) var sessions: [String: [TmuxSessionInfo]] = [:]
    @Published private(set) var reachable: [String: Bool] = [:]
    @Published private(set) var lastError: [String: String] = [:]
    @Published private(set) var external: [String: [ExternalClaude]] = [:]
    /// Wall time of the last poll per host, for diagnostics.
    @Published private(set) var lastPollDuration: [String: TimeInterval] = [:]

    private(set) var hosts: [Host]
    private(set) var isActive = false
    private var loops: [String: Task<Void, Never>] = [:]
    private var nextDue: [String: Date] = [:]
    /// Bumped by refreshNow so a poll already in flight does not push the next one out.
    private var refreshGeneration = 0

    static let fastInterval: TimeInterval = 1.5
    static let slowInterval: TimeInterval = 10

    init(hosts: [Host]) {
        self.hosts = hosts
    }

    var isRunning: Bool { !loops.isEmpty }

    func start() {
        for host in hosts where loops[host.id] == nil {
            nextDue[host.id] = .distantPast
            loops[host.id] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.tick(host)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    func stop() {
        loops.values.forEach { $0.cancel() }
        loops = [:]
    }

    /// Fast (with captures and external Claude processes) while the station is visible.
    func setActive(_ fast: Bool) {
        guard fast != isActive else { return }
        isActive = fast
        if fast { refreshNow() }
    }

    /// Polls every host as soon as its current poll (if any) finishes.
    func refreshNow() {
        refreshGeneration += 1
        for h in hosts { nextDue[h.id] = .distantPast }
    }

    /// True once this host answered (or failed) at least one poll.
    func hasPolled(host: Host) -> Bool { reachable[host.id] != nil }

    func sessionNames(host: Host) -> Set<String> {
        Set((sessions[host.id] ?? []).map(\.name))
    }

    /// First `ca-<host>-<n>` not in use on that host, per the last poll.
    func freeSessionName(host: Host) -> String {
        let used = sessionNames(host: host)
        var n = 1
        while used.contains("ca-\(host.id)-\(n)") { n += 1 }
        return "ca-\(host.id)-\(n)"
    }

    /// Polls are sequential per host, so they never overlap; hosts run in separate tasks.
    private func tick(_ host: Host) async {
        guard Date() >= nextDue[host.id] ?? .distantPast else { return }
        let fast = isActive
        let generation = refreshGeneration
        await poll(host, fast: fast)
        // A refresh during the poll (station just opened) means poll again right away.
        guard generation == refreshGeneration else { return }
        nextDue[host.id] = Date().addingTimeInterval(isActive ? Self.fastInterval : Self.slowInterval)
    }

    private func poll(_ host: Host, fast: Bool) async {
        let previous = Dictionary((sessions[host.id] ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let result = await Self.fetch(host: host, fast: fast, previous: previous)
        guard !Task.isCancelled else { return }
        lastPollDuration[host.id] = result.duration
        if let error = result.error {
            if reachable[host.id] != false { reachable[host.id] = false }
            lastError[host.id] = error
            return
        }
        if reachable[host.id] != true { reachable[host.id] = true }
        if lastError[host.id] != nil { lastError[host.id] = nil }
        if sessions[host.id] != result.sessions { sessions[host.id] = result.sessions }
        if fast, external[host.id] != result.external { external[host.id] = result.external }
    }

    struct FetchResult {
        var sessions: [TmuxSessionInfo] = []
        var external: [ExternalClaude] = []
        var error: String?
        var duration: TimeInterval = 0
    }

    /// Runs one poll and parses it, all off the main thread.
    nonisolated static func fetch(host: Host, fast: Bool, previous: [String: TmuxSessionInfo]) async -> FetchResult {
        let start = Date()
        let marker = "@@ca-" + UUID().uuidString.prefix(8).lowercased()
        let script = TmuxPoll.script(marker: marker, captures: fast, processes: fast)
        let r = await Runner.run(CommandBuilder.oneShot(host: host, script: script), timeout: 15)
        return await Task.detached(priority: .utility) {
            var res = FetchResult(duration: Date().timeIntervalSince(start))
            let out = TmuxPoll.parse(r.stdout, marker: marker)
            guard out.complete else {
                let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                res.error = err.isEmpty ? "poll failed (exit \(r.status))" : err
                return res
            }
            let offset = out.hostNow.map { Date().timeIntervalSince1970 - $0 } ?? 0
            // Ignore offsets that are just round trip latency.
            let clockOffset = abs(offset) > 3 ? offset : 0
            res.sessions = TmuxPoll.sessions(hostId: host.id, output: out, previous: previous,
                                             clockOffset: clockOffset, withCaptures: fast)
            if fast { res.external = TmuxPoll.externalClaudes(hostId: host.id, output: out) }
            return res
        }.value
    }
}
