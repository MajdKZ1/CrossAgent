import Foundation

/// Streams samples from an ssh host: one long lived `ssh` through the shared control
/// master running `LinuxSampler.script`. Restarts with backoff like EventFollower.
/// Samples and status changes arrive on the main actor.
final class RemoteSampler: @unchecked Sendable {
    enum Event {
        case sample(ActivitySample, sessions: [SessionLoad]?)
        case failed(String)
    }

    let host: Host
    private let onEvent: @MainActor (Event) -> Void
    private let queue = DispatchQueue(label: "crossagent.activity.remote")

    // Everything below is only touched on `queue`.
    private var process: Process?
    private var buffer = Data()
    private var errors = Data()
    private var running = false
    private var attempt = 0
    private var startedAt = Date()
    private var lastData = Date()
    private var watchdog: DispatchSourceTimer?
    private var accumulator = LinuxSampler.Accumulator()

    static let backoff: [TimeInterval] = [2, 5, 15, 30]
    /// A line comes every 1.5 s, so this much silence means the link is dead.
    static let silenceLimit: TimeInterval = 12

    init(host: Host, onEvent: @escaping @MainActor (Event) -> Void) {
        self.host = host
        self.onEvent = onEvent
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
        queue.async { [self] in
            running = false
            watchdog?.cancel()
            watchdog = nil
            if let p = process, p.isRunning { p.terminate() }
            process = nil
        }
    }

    // MARK: Internals (on queue)

    private func launch() {
        let cmd = LinuxSampler.command(host: host)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.executable)
        p.arguments = cmd.args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        buffer.removeAll()
        errors.removeAll()
        accumulator = LinuxSampler.Accumulator()
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            self.queue.async {
                guard self.process === p else { return }
                if data.isEmpty { fh.readabilityHandler = nil; return }
                self.consume(data)
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            self.queue.async {
                if data.isEmpty { fh.readabilityHandler = nil; return }
                if self.errors.count < 4096 { self.errors.append(data) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                guard self.process === proc else { return }
                self.process = nil
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if self.running { self.report(.failed(Self.reason(self.errors, status: proc.terminationStatus))) }
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
            report(.failed("couldn't start ssh"))
            scheduleRestart()
        }
    }

    /// Last meaningful stderr line, or a generic note.
    static func reason(_ stderr: Data, status: Int32) -> String {
        let lines = String(decoding: stderr, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.contains(where: { $0.contains("python3") && $0.contains("not found") }) { return "python3 isn't installed there" }
        if let last = lines.last { return String(last.prefix(120)) }
        return status == 255 ? "can't reach the host" : "sampler stopped (\(status))"
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
        for line in chunk.split(separator: 0x0A) {
            guard let raw = LinuxSampler.parse(Data(line)) else { continue }
            let sample = accumulator.sample(raw)
            report(.sample(sample, sessions: raw.sessions))
        }
    }

    private func report(_ e: Event) {
        let deliver = onEvent
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(e) } }
    }
}
