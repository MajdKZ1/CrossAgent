import Foundation

/// Follows ~/.crossagent/events on one host with one long lived process: the hook
/// script in `--follow` mode, locally or over ssh through the shared control master.
/// Restarts with backoff when the process dies and replays the last minute so a
/// dropped connection loses nothing. Events arrive on the main actor.
final class EventFollower: @unchecked Sendable {
    let host: Host
    private let onEvents: @MainActor ([AgentEvent]) -> Void
    private let queue = DispatchQueue(label: "crossagent.events.follower")

    // Everything below is only touched on `queue`.
    private var process: Process?
    /// Read end of the current process's stdout, so stop can detach it right away.
    private var reader: FileHandle?
    private var buffer = Data()
    private var running = false
    private var attempt = 0
    private var lastSeenTS: Double?
    private var lastData = Date()
    private var startedAt = Date()
    private var seen = EventDedupe()
    private var watchdog: DispatchSourceTimer?
    private var initialReplay: TimeInterval
    private let makeCommand: (Double?) -> SpawnCommand

    static let backoff: [TimeInterval] = [2, 5, 15, 30]
    static let replayOnRestart: TimeInterval = 60
    /// The follower prints a heartbeat every 2 s. Silence for this long means the link is dead.
    static let silenceLimit: TimeInterval = 40

    /// `replay` seconds of history are sent on the first start, so a freshly opened
    /// window shows what is already going on.
    /// `command` replaces the real follower command, for tests.
    init(host: Host, replay: TimeInterval = 120, command: ((Double?) -> SpawnCommand)? = nil,
         onEvents: @escaping @MainActor ([AgentEvent]) -> Void) {
        self.host = host
        self.makeCommand = command ?? { EventFollower.command(host: host, since: $0) }
        self.initialReplay = replay
        self.onEvents = onEvents
        Self.liveLock.withLock { Self.live.add(self) }
    }

    /// Every follower ever made, held weakly, so quitting can stop them all at once.
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static let live = NSHashTable<EventFollower>.weakObjects()

    /// Stops every follower synchronously, so no ssh follower outlives the app.
    static func shutdownAll() {
        for f in liveLock.withLock({ live.allObjects }) { f.shutdown() }
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

    /// For app termination: stops now and waits up to `timeout` for the process to exit,
    /// then kills it, so no follower is left running with ppid 1.
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

    /// The command that runs the follower on the host.
    static func command(host: Host, since: Double?) -> SpawnCommand {
        var script = "exec python3 -I ~/\(HookInstaller.scriptRelativePath) --follow ~/.crossagent/events"
        if let since { script += " --since " + String(format: "%.3f", since) }
        return CommandBuilder.oneShot(host: host, script: script)
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
        let since = lastSeenTS.map { $0 - Self.replayOnRestart }
            ?? (initialReplay > 0 ? Date().timeIntervalSince1970 - initialReplay : nil)
        let cmd = makeCommand(since)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.executable)
        p.arguments = cmd.args
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
        // A run that lasted a while was healthy: start the backoff over.
        if Date().timeIntervalSince(startedAt) > 60 { attempt = 0 }
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            if running, process == nil { launch() }
        }
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10)
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
        var events: [AgentEvent] = []
        for line in chunk.split(separator: 0x0A) {
            guard let e = Self.parse(Data(line)) else { continue }
            lastSeenTS = max(lastSeenTS ?? 0, e.ts)
            if seen.insert(e) { events.append(e) }
        }
        guard !events.isEmpty else { return }
        // Async hooks can land a few ms out of order; deliver each batch sorted.
        events.sort { $0.ts < $1.ts }
        let deliver = onEvents
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(events) } }
    }

    /// Tolerant line parser: blank, broken or foreign lines give nil.
    static func parse(_ line: Data) -> AgentEvent? {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D }) else { return nil }
        return try? JSONDecoder().decode(AgentEvent.self, from: line)
    }
}

/// Remembers recently seen events by (sid, ts, ev, tuid) so replays after a
/// reconnect do not apply twice. Bounded.
struct EventDedupe {
    private var set = Set<String>()
    private var order: [String] = []
    var limit = 4000

    /// True when the event is new.
    mutating func insert(_ e: AgentEvent) -> Bool {
        let key = "\(e.sid ?? "")|\(e.ts)|\(e.ev)|\(e.tuid ?? "")|\(e.aid ?? "")"
        guard set.insert(key).inserted else { return false }
        order.append(key)
        if order.count > limit {
            let drop = order.prefix(limit / 4)
            for k in drop { set.remove(k) }
            order.removeFirst(drop.count)
        }
        return true
    }
}
