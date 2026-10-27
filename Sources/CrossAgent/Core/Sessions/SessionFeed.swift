import Foundation

/// What a feed source hands the main actor in one go.
struct FeedBatch {
    var items: [TranscriptItem] = []
    /// Subagent metas that appeared or changed: (agentId, meta, file mtime).
    var metas: [(String, SubagentMeta, Date)] = []
    /// Set when the session file changed. `.some(nil)`: no live process any more.
    var session: SessionFile?? = nil
    var isEmpty: Bool { items.isEmpty && metas.isEmpty && session == nil }
}

/// Turns tagged lines from either source into a batch: one parser per file, items seen
/// before (a restarted follower replays) dropped, each batch in time order.
struct FeedDecoder {
    var includeThinking = false
    private var parsers: [String: TranscriptParser] = [:]
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    static let seenLimit = 20000

    /// `tag`: "m", "a:<agentId>", "meta:<agentId>", "s", "hb".
    mutating func add(tag: Substring, payload: Data, into batch: inout FeedBatch) {
        if tag == "m" || tag.hasPrefix("a:") {
            let key = String(tag)
            var p = parsers[key] ?? TranscriptParser(agentId: tag.hasPrefix("a:") ? String(tag.dropFirst(2)) : nil,
                                                      includeThinking: includeThinking)
            for it in p.parse(payload) where remember(it.id + (it.agentId ?? "")) { batch.items.append(it) }
            parsers[key] = p
        } else if tag.hasPrefix("meta:") {
            guard let d = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let m = d["meta"], let md = try? JSONSerialization.data(withJSONObject: m),
                  let meta = SubagentMeta.parse(md) else { return }
            let t = (d["mtime"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            batch.metas.removeAll { $0.0 == String(tag.dropFirst(5)) }
            batch.metas.append((String(tag.dropFirst(5)), meta, t))
        } else if tag == "s" {
            batch.session = .some(SessionFile.parse(payload))
        }
    }

    /// Parses `<tag>\t<payload>` lines.
    mutating func add(line: Data, into batch: inout FeedBatch) {
        guard let tab = line.firstIndex(of: 0x09) else { return }
        let tag = String(decoding: line[line.startIndex..<tab], as: UTF8.self)
        add(tag: Substring(tag), payload: Data(line[(tab + 1)...]), into: &batch)
    }

    /// Time order, stable: files interleave, lines within a file keep their order.
    static func sortItems(_ items: inout [TranscriptItem]) {
        items = items.enumerated().sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }.map(\.element)
    }

    private mutating func remember(_ id: String) -> Bool {
        guard seen.insert(id).inserted else { return false }
        seenOrder.append(id)
        if seenOrder.count > Self.seenLimit {
            for old in seenOrder.prefix(seenOrder.count - Self.seenLimit) { seen.remove(old) }
            seenOrder.removeFirst(seenOrder.count - Self.seenLimit)
        }
        return true
    }
}

/// A feed's data source. Batches arrive on the main actor.
protocol FeedSource: AnyObject, Sendable {
    func start()
    func stop()
    func shutdown(timeout: TimeInterval)
}

/// Tails a session's files on this Mac by byte offset, with a cheap stat timer. Never
/// reads a file from 0 twice; a partial last line waits for its newline.
final class LocalTranscriptTailer: FeedSource, @unchecked Sendable {
    let root: String
    let sessionId: String
    private let onBatch: @MainActor (FeedBatch) -> Void
    private let queue = DispatchQueue(label: "crossagent.sessions.tail")
    static let interval: TimeInterval = 0.75
    /// Bytes read back when a file is first opened. Older history is skipped.
    static let initialCap = 16 << 20

    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var decoder = FeedDecoder()
    private var main: String?
    private var files: [String: (offset: UInt64, partial: Data, skipFirst: Bool)] = [:]
    private var metaTimes: [String: Date] = [:]
    private var lastSession: Data?? = nil
    private var nextSessionCheck = Date.distantPast
    private var nextFind = Date.distantPast

    init(root: String, sessionId: String, onBatch: @escaping @MainActor (FeedBatch) -> Void) {
        self.root = root
        self.sessionId = sessionId
        self.onBatch = onBatch
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in timer?.cancel(); timer = nil }
    }

    func shutdown(timeout: TimeInterval = 0.5) {
        queue.sync { timer?.cancel(); timer = nil }
    }

    private func tick() {
        var batch = FeedBatch()
        let now = Date()
        let fm = FileManager.default
        if main == nil, now >= nextFind {
            nextFind = now.addingTimeInterval(2)
            let projects = root + "/projects"
            for d in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let p = "\(projects)/\(d)/\(sessionId).jsonl"
                if fm.fileExists(atPath: p) { main = p; break }
            }
        }
        if let main {
            pump(main, tag: "m", into: &batch)
            let sub = ClaudePaths.subagentsDir(transcript: main)
            for n in ((try? fm.contentsOfDirectory(atPath: sub)) ?? []).sorted() {
                guard let aid = ClaudePaths.agentId(fileName: n) else { continue }
                let p = sub + "/" + n
                if n.hasSuffix(".jsonl") {
                    pump(p, tag: "a:" + aid, into: &batch)
                } else if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, metaTimes[p] != m,
                          let data = fm.contents(atPath: p), let meta = SubagentMeta.parse(data) {
                    metaTimes[p] = m
                    batch.metas.append((aid, meta, m))
                }
            }
        }
        if now >= nextSessionCheck {
            nextSessionCheck = now.addingTimeInterval(1)
            let cur = currentSessionFile()
            if lastSession == nil || lastSession! != cur {
                lastSession = .some(cur)
                batch.session = .some(cur.flatMap(SessionFile.parse))
            }
        }
        guard !batch.isEmpty else { return }
        FeedDecoder.sortItems(&batch.items)
        let deliver = onBatch
        let b = batch
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(b) } }
    }

    private func pump(_ path: String, tag: String, into batch: inout FeedBatch) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else { return }
        let total = size.uint64Value
        var st = files[path] ?? {
            let off = total > UInt64(Self.initialCap) ? total - UInt64(Self.initialCap) : 0
            return (off, Data(), off > 0)
        }()
        if total < st.offset { st = (0, Data(), false) }
        guard total > st.offset, let fh = FileHandle(forReadingAtPath: path) else { files[path] = st; return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: st.offset)
        let data = (try? fh.read(upToCount: Int(min(total - st.offset, 8 << 20)))) ?? Data()
        st.offset += UInt64(data.count)
        var buf = st.partial + data
        if let nl = buf.lastIndex(of: 0x0A) {
            var lines = buf[buf.startIndex..<nl].split(separator: 0x0A, omittingEmptySubsequences: false)
            buf = Data(buf[(nl + 1)...])
            if st.skipFirst, !lines.isEmpty { lines.removeFirst(); st.skipFirst = false }
            for l in lines where !l.isEmpty { decoder.add(tag: Substring(tag), payload: Data(l), into: &batch) }
        }
        st.partial = buf
        files[path] = st
    }

    /// The live session file for this session, if its process is alive.
    private func currentSessionFile() -> Data? {
        let dir = root + "/sessions"
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + n),
                  let f = SessionFile.parse(data), f.sessionId == sessionId else { continue }
            if kill(f.pid, 0) == 0 || errno == EPERM { return data }
        }
        return nil
    }
}

/// Follows a session on an ssh host with one long lived ssh running
/// `SessionScripts.follower`. Restarts with backoff; the decoder drops what a restart replays.
final class RemoteTranscriptFollower: FeedSource, @unchecked Sendable {
    private let command: SpawnCommand
    private let onBatch: @MainActor (FeedBatch) -> Void
    private let queue = DispatchQueue(label: "crossagent.sessions.follow")

    // Only touched on `queue`.
    private var process: Process?
    private var reader: FileHandle?
    private var buffer = Data()
    private var running = false
    private var attempt = 0
    private var startedAt = Date()
    private var lastData = Date()
    private var watchdog: DispatchSourceTimer?
    private var decoder = FeedDecoder()

    static let backoff: [TimeInterval] = [2, 5, 15, 30]
    /// The follower beats every 2 s.
    static let silenceLimit: TimeInterval = 12

    /// `command` replaces the ssh follower, for tests.
    init(host: Host, root: String = "~/.claude", sessionId: String, command: SpawnCommand? = nil,
         onBatch: @escaping @MainActor (FeedBatch) -> Void) {
        self.command = command ?? Self.command(host: host, root: root, sessionId: sessionId)
        self.onBatch = onBatch
    }

    static func command(host: Host, root: String, sessionId: String) -> SpawnCommand {
        let args = [root, sessionId, String(LocalTranscriptTailer.initialCap)].map(CommandBuilder.shellQuote).joined(separator: " ")
        return CommandBuilder.oneShot(host: host, script: "exec python3 -I -u -c \(CommandBuilder.shellQuote(SessionScripts.follower)) \(args)")
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            attempt = 0
            launch()
            startWatchdog()
        }
    }

    func stop() {
        queue.async { [self] in halt() }
    }

    /// Stops now and waits up to `timeout` for the process to exit, then kills it.
    func shutdown(timeout: TimeInterval = 0.5) {
        let p = queue.sync { () -> Process? in
            let p = process
            halt()
            return p
        }
        guard let p, p.isRunning else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(10_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    // MARK: Internals (on queue)

    private func halt() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        reader?.readabilityHandler = nil
        reader = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command.executable)
        p.arguments = command.args
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        buffer.removeAll()
        // The handler detaches itself at EOF before anything else: a handler left on a
        // pipe at EOF fires nonstop and burns a core.
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; return }
            guard let self else { return }
            self.queue.async {
                guard self.process === p else { return }
                self.consume(data)
            }
        }
        reader = out.fileHandleForReading
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                guard self.process === proc else { return }
                self.process = nil
                self.reader = nil
                self.scheduleRestart()
            }
        }
        startedAt = Date()
        lastData = Date()
        process = p
        do {
            try p.run()
        } catch {
            process = nil
            reader?.readabilityHandler = nil
            reader = nil
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard running else { return }
        if Date().timeIntervalSince(startedAt) > 60 { attempt = 0 }
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            if running, process == nil { launch() }
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, let p = self.process, p.isRunning else { return }
            if Date().timeIntervalSince(self.lastData) > Self.silenceLimit { p.terminate() }
        }
        t.resume()
        watchdog = t
    }

    private func consume(_ data: Data) {
        lastData = Date()
        buffer.append(data)
        guard let nl = buffer.lastIndex(of: 0x0A) else { return }
        let chunk = buffer[buffer.startIndex...nl]
        buffer = Data(buffer[(nl + 1)...])
        var batch = FeedBatch()
        for line in chunk.split(separator: 0x0A) { decoder.add(line: Data(line), into: &batch) }
        guard !batch.isEmpty else { return }
        FeedDecoder.sortItems(&batch.items)
        let deliver = onBatch
        let b = batch
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(b) } }
    }
}

/// The live (or replayed) transcript of one session plus its agent graph. One per
/// session, shared by every view showing it; runs while anyone has retained it.
@MainActor
final class SessionFeed: ObservableObject {
    let hostId: String
    let sessionId: String
    @Published private(set) var items: [TranscriptItem] = []
    @Published private(set) var status: ClaudeSessionStatus
    let graph: AgentGraph
    private let reducer: TranscriptReducer
    private var source: FeedSource?
    private let makeSource: (SessionFeed) -> FeedSource
    private var viewers = 0
    private var ticker: Timer?
    /// Where the session runs, to find its project's remote workers. Discovery's when nil.
    private var cwd: String?
    private var remoteSeq = 0

    static let maxItems = 3000

    private static var registry = NSMapTable<NSString, SessionFeed>.strongToWeakObjects()

    /// The shared feed for a session. Hold on to it and call `retain()` to start it.
    static func feed(host: String, sessionId: String) -> SessionFeed {
        let key = "\(host):\(sessionId)" as NSString
        if let f = registry.object(forKey: key) { return f }
        let discovery = SessionDiscovery.shared
        let h = discovery.host(host) ?? HostStore.defaults.first { $0.id == host }
            ?? Host(id: host, name: host, type: .ssh, target: host, accent: "")
        let known = discovery.session(host: host, sessionId: sessionId)
        let f = SessionFeed(host: h, sessionId: sessionId, tmuxSession: known?.tmuxSession, status: known?.status ?? .idle,
                            cwd: known?.cwd)
        f.graph.hosts = discovery.hosts
        registry.setObject(f, forKey: key)
        f.pullRemoteEvents()
        return f
    }

    /// `localRoot` is ~/.claude for a local host. `source` replaces the real one, for tests.
    init(host: Host, sessionId: String, tmuxSession: String? = nil, status: ClaudeSessionStatus = .idle,
         cwd: String? = nil, localRoot: String? = nil, source: ((SessionFeed) -> FeedSource)? = nil) {
        self.hostId = host.id
        self.sessionId = sessionId
        self.status = status
        self.cwd = cwd.flatMap { $0.isEmpty ? nil : $0 }
        self.graph = AgentGraph(orchestratorHost: host.id, session: tmuxSession)
        self.reducer = TranscriptReducer(graph: graph)
        let root = localRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        self.makeSource = source ?? { feed in
            let deliver: @MainActor (FeedBatch) -> Void = { [weak feed] b in feed?.apply(b) }
            if DemoMode.isOn { return DemoFeedSource(sessionId: sessionId, live: status != .ended, onBatch: deliver) }
            if host.isLocal { return LocalTranscriptTailer(root: root, sessionId: sessionId, onBatch: deliver) }
            return RemoteTranscriptFollower(host: host, sessionId: sessionId, onBatch: deliver)
        }
    }

    func retain() {
        viewers += 1
        guard viewers == 1 else { return }
        let s = source ?? makeSource(self)
        source = s
        s.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reducer.tick(now: Date()) }
        }
    }

    func release() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        source?.stop()
        ticker?.invalidate()
        ticker = nil
    }

    /// The graph node an item's subagent belongs to: its Agent call's id. Nil for the main thread.
    func nodeId(forAgent agentId: String) -> String? { reducer.node(forAgent: agentId) }

    /// Applies the remote worker events of the session's project not applied yet.
    func pullRemoteEvents() {
        if cwd == nil { cwd = SessionDiscovery.shared.session(host: hostId, sessionId: sessionId).flatMap { $0.cwd.isEmpty ? nil : $0.cwd } }
        guard let cwd, let project = RemoteEventLog.project(host: hostId, cwd: cwd) else { return }
        reducer.slug = project
        for entry in RemoteEventLog.entries(project: project, after: remoteSeq) {
            graph.applyRemote(entry.event, at: Date(timeIntervalSince1970: entry.event.ts))
            remoteSeq = entry.seq
        }
    }

    /// Every open feed catches up on remote worker events.
    static func pullRemoteEvents() {
        for case let f as SessionFeed in registry.objectEnumerator()?.allObjects ?? [] { f.pullRemoteEvents() }
    }

    /// Stops every open feed, for app termination.
    static func shutdownAll() {
        for case let f as SessionFeed in registry.objectEnumerator()?.allObjects ?? [] { f.shutdown() }
    }

    /// Stops the source right away, for app termination and tests.
    func shutdown() {
        viewers = 0
        source?.shutdown(timeout: 0.5)
        ticker?.invalidate()
        ticker = nil
    }

    func apply(_ b: FeedBatch) {
        if !b.items.isEmpty {
            var all = items
            let tail = all.last?.at
            all.append(contentsOf: b.items)
            // The PC follower sends each file's lines as they come, so a subagent's lines
            // can land after later main lines. Put them back in time order.
            if let tail, b.items.contains(where: { $0.at < tail }) { FeedDecoder.sortItems(&all) }
            if all.count > Self.maxItems { all.removeFirst(all.count - Self.maxItems) }
            items = all
            reducer.apply(b.items)
            pullRemoteEvents()
        }
        for (aid, meta, t) in b.metas { reducer.apply(meta: meta, agentId: aid, at: t) }
        if let s = b.session {
            let st: ClaudeSessionStatus = s.map(\.sessionStatus) ?? .ended
            if st != status { status = st }
            reducer.applyStatus(st, waitingFor: s?.waitingFor, at: Date())
        }
    }
}
