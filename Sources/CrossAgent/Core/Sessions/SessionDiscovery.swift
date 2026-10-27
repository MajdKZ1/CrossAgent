import Foundation

/// One session as a scan sees it, before it becomes a `ClaudeSession`. The Mac scanner
/// and the PC discovery script both produce this shape.
struct RawSession: Codable, Equatable {
    var sid: String
    var cwd: String?
    var pid: Int32?
    var tty: String?
    /// Ancestor command names, nearest first.
    var chain: [String]?
    var tmux: String?
    var path: String
    var name: String?
    var nameSource: String?
    var status: String?
    var waitingFor: String?
    var started: Double?
    var statusAt: Double?
    var mtime: Double?
    var size: Int?
    var subagents: Int?
    /// Only when the scan (re)read the head.
    var head: TranscriptHead?
    var headFull: Bool?
}

/// The PC discovery script's output.
struct RemoteScan: Codable {
    var running: [RawSession]
    var recent: [RawSession]?
    var now: Double?
}

/// Transcript heads already read, by path. A head is final once the file was at least
/// `TranscriptHead.maxBytes` long when read; until then it's read again when the size changes.
struct HeadCache {
    struct Entry { var size: Int; var full: Bool; var head: TranscriptHead }
    private(set) var entries: [String: Entry] = [:]

    func needsScan(path: String, size: Int) -> Bool {
        guard let e = entries[path] else { return true }
        return !e.full && e.size != size
    }

    mutating func store(path: String, size: Int, head: TranscriptHead) {
        entries[path] = Entry(size: size, full: size >= TranscriptHead.maxBytes, head: head)
    }

    func head(_ path: String) -> TranscriptHead? { entries[path]?.head }

    /// For the PC script: size per path, -1 when final.
    var known: [String: Int] { entries.mapValues { $0.full ? -1 : $0.size } }

    /// Fills `raw.head` from the cache, or stores a fresh one the scan brought.
    mutating func resolve(_ raw: inout RawSession) {
        if let h = raw.head, let size = raw.size {
            entries[raw.path] = Entry(size: size, full: raw.headFull ?? (size >= TranscriptHead.maxBytes), head: h)
        } else {
            raw.head = entries[raw.path]?.head
        }
    }

    mutating func prune(keeping paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }
}

extension ClaudeSession {
    /// Builds the session from a scan record. `raw.head` should be resolved already.
    static func make(hostId: String, raw: RawSession, now: Date = Date()) -> ClaudeSession {
        let head = raw.head
        let cwd = raw.cwd ?? head?.cwd ?? ""
        let running = raw.pid != nil
        let mtime = raw.mtime.map { Date(timeIntervalSince1970: $0) }
        let statusAt = raw.statusAt.map { Date(timeIntervalSince1970: $0) }
        let last = [mtime, statusAt].compactMap { $0 }.max() ?? now
        let status: ClaudeSessionStatus
        if !running {
            status = .ended
        } else {
            switch raw.status {
            case "busy": status = .running
            case "waiting": status = .waiting
            case "idle": status = .idle
            default: status = (mtime.map { now.timeIntervalSince($0) < 10 } ?? false) ? .running : .idle
            }
        }
        let userName = raw.nameSource == "derived" ? nil : raw.name
        let launcher: SessionLauncher = running ? LauncherClassifier.classify(chain: raw.chain ?? [], tmuxSession: raw.tmux) : .ended
        return ClaudeSession(
            hostId: hostId, sessionId: raw.sid, cwd: cwd, pid: raw.pid, tty: raw.tty, launcher: launcher,
            tmuxSession: running ? raw.tmux : nil, transcriptPath: raw.path,
            title: SessionTitle.make(userName: userName, aiTitle: head?.aiTitle, prompt: head?.prompt,
                                     derivedName: raw.nameSource == "derived" ? raw.name : nil, cwd: cwd),
            status: status,
            startedAt: (raw.started ?? head?.started).map { Date(timeIntervalSince1970: $0) } ?? mtime ?? now,
            lastActivity: last, subagentCount: raw.subagents ?? 0)
    }
}

/// Scans ~/.claude on this Mac. Only touched on its own queue. Process lookups are
/// injectable for tests.
final class LocalSessionScanner: @unchecked Sendable {
    let root: String
    var processes: () -> [Int32: ProcInfo]
    var tmuxPanes: () -> [Int32: String]
    var isAlive: (Int32) -> Bool
    private(set) var heads = HeadCache()
    /// Launcher facts per pid and procStart, so `ps` only runs when a new session shows up.
    private var procCache: [String: (ok: Bool, tty: String?, chain: [String], pids: [Int32])] = [:]

    init(root: String,
         processes: @escaping () -> [Int32: ProcInfo] = LocalSessionScanner.psTable,
         tmuxPanes: @escaping () -> [Int32: String] = LocalSessionScanner.localTmuxPanes,
         isAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.root = root
        self.processes = processes
        self.tmuxPanes = tmuxPanes
        self.isAlive = isAlive
    }

    func running() -> [RawSession] {
        let dir = root + "/sessions"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let files = names.filter { $0.hasSuffix(".json") }.compactMap { n -> SessionFile? in
            FileManager.default.contents(atPath: dir + "/" + n).flatMap(SessionFile.parse)
        }.filter { isAlive($0.pid) }
        var table: [Int32: ProcInfo]?
        var out: [RawSession] = []
        var live = Set<String>()
        for f in files {
            let key = "\(f.pid) \(f.procStart ?? "")"
            live.insert(key)
            if procCache[key] == nil {
                if table == nil { table = processes() }
                if let p = table?[f.pid] {
                    var pids: [Int32] = []
                    var q = p.ppid
                    while q > 1, let i = table?[q], pids.count < 32 { pids.append(q); q = i.ppid }
                    procCache[key] = (ProcInfo.sameStart(f.procStart, lstart: p.lstart), p.tty,
                                      ProcInfo.ancestors(of: f.pid, in: table!), pids)
                } else {
                    procCache[key] = (false, nil, [], [])
                }
            }
            guard let pc = procCache[key], pc.ok else { continue }
            var tmux = f.tmuxSession
            if tmux == nil, pc.chain.contains(where: { ($0.split(separator: "/").last ?? "").hasPrefix("tmux") }) {
                let panes = tmuxPanes()
                tmux = pc.pids.lazy.compactMap { panes[$0] }.first
            }
            var raw = RawSession(sid: f.sessionId, cwd: f.cwd, pid: f.pid, tty: pc.tty, chain: pc.chain, tmux: tmux,
                                 path: ClaudePaths.transcript(root: root, cwd: f.cwd, sessionId: f.sessionId),
                                 name: f.name, nameSource: f.nameSource, status: f.status, waitingFor: f.waitingFor,
                                 started: f.startedAt.map { $0 / 1000 }, statusAt: f.statusUpdatedAt.map { $0 / 1000 })
            fill(&raw)
            out.append(raw)
        }
        procCache = procCache.filter { live.contains($0.key) }
        return out
    }

    /// Transcripts written within `days`, minus the running ones.
    func recent(days: Int, excluding running: Set<String>, now: Date = Date()) -> [RawSession] {
        let fm = FileManager.default
        let projects = root + "/projects"
        let cut = now.timeIntervalSince1970 - Double(days) * 86400
        var out: [RawSession] = []
        for d in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let dir = projects + "/" + d
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
                let sid = String(f.dropLast(6))
                guard UUID(uuidString: sid) != nil, !running.contains(sid) else { continue }
                let path = dir + "/" + f
                guard let a = try? fm.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeRegular,
                      let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970, m >= cut else { continue }
                var raw = RawSession(sid: sid, path: path)
                fill(&raw)
                out.append(raw)
            }
        }
        return out
    }

    func pruneHeads(keeping paths: Set<String>) { heads.prune(keeping: paths) }

    /// mtime, size, subagent count and the head (cached).
    private func fill(_ raw: inout RawSession) {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: raw.path) else { return }
        raw.mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970
        let size = (a[.size] as? NSNumber)?.intValue ?? 0
        raw.size = size
        raw.subagents = ((try? fm.contentsOfDirectory(atPath: ClaudePaths.subagentsDir(transcript: raw.path))) ?? [])
            .filter { $0.hasSuffix(".meta.json") }.count
        if heads.needsScan(path: raw.path, size: size), let fh = FileHandle(forReadingAtPath: raw.path) {
            let data = (try? fh.read(upToCount: TranscriptHead.maxBytes)) ?? Data()
            try? fh.close()
            heads.store(path: raw.path, size: size, head: TranscriptHead.scan(data))
        }
        raw.head = heads.head(raw.path)
    }

    /// `ps` in UTC so lstart matches the session file's procStart.
    static func psTable() -> [Int32: ProcInfo] {
        let r = Runner.runSync(SpawnCommand(executable: "/usr/bin/env",
                                            args: ["TZ=UTC", "LC_ALL=C", "/bin/ps", "-axo", "pid=,ppid=,tty=,lstart=,comm="]),
                               timeout: 5)
        return ProcInfo.parsePS(r.stdout)
    }

    static func localTmuxPanes() -> [Int32: String] {
        let host = Host(id: "mac", name: "", type: .local, target: nil, accent: "")
        let r = Runner.runSync(CommandBuilder.oneShot(host: host, script: "tmux list-panes -a -F '#{pane_pid} #{session_name}'"), timeout: 5)
        var out: [Int32: String] = [:]
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let pid = Int32(parts[0]) { out[pid] = String(parts[1]) }
        }
        return out
    }
}

/// Every Claude Code session on every host, running or recently ended. Polls only while
/// someone is looking: running sessions every 3 s, the ended list every 30 s.
@MainActor
final class SessionDiscovery: ObservableObject {
    static let shared = SessionDiscovery()

    @Published private(set) var sessions: [ClaudeSession] = []
    /// Last failure per host id, cleared on the next good poll.
    @Published private(set) var hostErrors: [String: String] = [:]

    static let recentDaysKey = "sessions.recentDays"
    static let runningInterval: TimeInterval = 3
    static let recentInterval: TimeInterval = 30

    var recentDays: Int {
        get { let d = defaults.integer(forKey: Self.recentDaysKey); return d > 0 ? d : 7 }
        set { defaults.set(newValue, forKey: Self.recentDaysKey); lastRecent = [:] }
    }

    let hosts: [Host]
    private let defaults: UserDefaults
    private let local: LocalSessionScanner
    private let localQueue = DispatchQueue(label: "crossagent.sessions.discovery")
    private let remoteRoot: String
    private let remoteCommand: ((Host, [String]) -> SpawnCommand)?
    private var remoteHeads: [String: HeadCache] = [:]
    private var running: [String: [ClaudeSession]] = [:]
    private var recent: [String: [ClaudeSession]] = [:]
    private var lastRecent: [String: Date] = [:]
    private var viewers = 0
    private var loops: [String: Task<Void, Never>] = [:]

    /// `localRoot` is ~/.claude on this Mac, `remoteRoot` the same on ssh hosts.
    /// `remoteCommand` replaces the ssh call (host, script argv) for tests.
    init(hosts: [Host] = HostStore.load(), localRoot: String? = nil, remoteRoot: String = "~/.claude",
         defaults: UserDefaults = .standard, scanner: LocalSessionScanner? = nil,
         remoteCommand: ((Host, [String]) -> SpawnCommand)? = nil) {
        self.hosts = hosts
        self.defaults = defaults
        let root = localRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        self.local = scanner ?? LocalSessionScanner(root: root)
        self.remoteRoot = remoteRoot
        self.remoteCommand = remoteCommand
    }

    func host(_ id: String) -> Host? { hosts.first { $0.id == id } }

    func addViewer() {
        viewers += 1
        if viewers == 1 { startLoops() }
    }

    func removeViewer() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stopLoops() }
    }

    func isRunning(host: String, sessionId: String) -> Bool {
        sessions.contains { $0.hostId == host && $0.sessionId == sessionId && $0.isRunning }
    }

    func session(host: String, sessionId: String) -> ClaudeSession? {
        sessions.first { $0.hostId == host && $0.sessionId == sessionId }
    }

    /// One poll of every host now, ended lists included. For tests and a manual refresh.
    func refresh() async {
        lastRecent = [:]
        await withTaskGroup(of: Void.self) { group in
            for h in hosts { group.addTask { await self.poll(h) } }
        }
    }

    // MARK: Polling

    private func startLoops() {
        for h in hosts where loops[h.id] == nil {
            loops[h.id] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.poll(h)
                    try? await Task.sleep(nanoseconds: UInt64(Self.runningInterval * 1e9))
                }
            }
        }
    }

    private func stopLoops() {
        for t in loops.values { t.cancel() }
        loops = [:]
    }

    private func poll(_ host: Host) async {
        let now = Date()
        let wantRecent = now.timeIntervalSince(lastRecent[host.id] ?? .distantPast) >= Self.recentInterval
        if wantRecent { lastRecent[host.id] = now }
        if host.isLocal {
            await pollLocal(host, wantRecent: wantRecent)
        } else {
            await pollRemote(host, wantRecent: wantRecent)
        }
    }

    private func pollLocal(_ host: Host, wantRecent: Bool) async {
        let days = recentDays
        let scanner = local
        let (run, rec): ([RawSession], [RawSession]?) = await withCheckedContinuation { cont in
            localQueue.async {
                let run = scanner.running()
                let rec = wantRecent ? scanner.recent(days: days, excluding: Set(run.map(\.sid))) : nil
                if let rec { scanner.pruneHeads(keeping: Set((run + rec).map(\.path))) }
                cont.resume(returning: (run, rec))
            }
        }
        publish(host.id, running: run, recent: rec)
        hostErrors[host.id] = nil
    }

    private func pollRemote(_ host: Host, wantRecent: Bool) async {
        var cache = remoteHeads[host.id] ?? HeadCache()
        let known = String(decoding: (try? JSONEncoder().encode(cache.known)) ?? Data("{}".utf8), as: UTF8.self)
        let argv = [remoteRoot, wantRecent ? "1" : "0", String(recentDays), known]
        let cmd = remoteCommand?(host, argv) ?? Self.remoteCommand(host: host, argv: argv)
        let r = await Runner.run(cmd, timeout: 20)
        guard r.status == 0, let line = r.stdout.split(whereSeparator: \.isNewline).last,
              let scan = try? JSONDecoder().decode(RemoteScan.self, from: Data(line.utf8)) else {
            if wantRecent { lastRecent[host.id] = nil }
            hostErrors[host.id] = RemoteSampler.reason(Data(r.stderr.utf8), status: r.status)
            return
        }
        var run = scan.running
        var rec = scan.recent
        for i in run.indices { cache.resolve(&run[i]) }
        if rec != nil { for i in rec!.indices { cache.resolve(&rec![i]) } }
        if let rec { cache.prune(keeping: Set((run + rec).map(\.path))) }
        remoteHeads[host.id] = cache
        publish(host.id, running: run, recent: rec)
        hostErrors[host.id] = nil
    }

    static func remoteCommand(host: Host, argv: [String]) -> SpawnCommand {
        let args = argv.map(CommandBuilder.shellQuote).joined(separator: " ")
        return CommandBuilder.oneShot(host: host, script: "exec python3 -I -c \(CommandBuilder.shellQuote(SessionScripts.discovery)) \(args)")
    }

    private func publish(_ hostId: String, running run: [RawSession], recent rec: [RawSession]?) {
        let now = Date()
        let newRunning = run.map { ClaudeSession.make(hostId: hostId, raw: $0, now: now) }
        let ids = Set(newRunning.map(\.sessionId))
        var ended: [ClaudeSession]
        if let rec {
            // A transcript with no cwd is a stub with no conversation in it (nothing to
            // show, nowhere to resume), so it's left out.
            ended = rec.map { ClaudeSession.make(hostId: hostId, raw: $0, now: now) }.filter { !$0.cwd.isEmpty }
        } else {
            ended = (recent[hostId] ?? []).filter { !ids.contains($0.sessionId) }
        }
        // Sessions that just stopped show as ended right away, not at the next slow scan.
        let endedIds = Set(ended.map(\.sessionId))
        for var s in running[hostId] ?? [] where !ids.contains(s.sessionId) && !endedIds.contains(s.sessionId) {
            s.pid = nil
            s.tty = nil
            s.tmuxSession = nil
            s.launcher = .ended
            s.status = .ended
            ended.append(s)
        }
        running[hostId] = newRunning
        recent[hostId] = ended
        let all = hosts.flatMap { (running[$0.id] ?? []) + (recent[$0.id] ?? []) }
        let sorted = all.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.lastActivity > $1.lastActivity
        }
        if sorted != sessions { sessions = sorted }
    }
}

enum SessionResume {
    /// Shell line that resumes a session where it ran: `cd <cwd> && claude --resume <id>`.
    static func script(sessionId: String, cwd: String) -> String {
        "cd \(CommandBuilder.shellPath(cwd)) && claude --resume \(CommandBuilder.shellQuote(sessionId))"
    }
}
