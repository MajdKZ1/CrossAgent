import AppKit

/// How a Mutagen session (or all of them) is doing. The UI shows it as a Crossover
/// Portal state, see `SyncSession.portal(crossing:)`.
enum SyncHealth: Int, Comparable {
    case ok, busy, problem

    static func < (a: SyncHealth, b: SyncHealth) -> Bool { a.rawValue < b.rawValue }

    var name: String {
        switch self {
        case .ok: return "green"
        case .busy: return "amber"
        case .problem: return "red"
        }
    }
}

/// One Mutagen sync session from `mutagen sync list --template '{{json .}}'`.
/// Every field is optional and decoded leniently so a new Mutagen version can't break it.
struct SyncSession: Decodable, Equatable, Identifiable {
    struct Problem: Decodable, Equatable {
        var path: String?
        var error: String?
    }

    struct Endpoint: Decodable, Equatable {
        var `protocol`: String?
        var host: String?
        var path: String?
        var connected: Bool?
        var scanProblems: [Problem]?
        var transitionProblems: [Problem]?
        var excludedScanProblems: Int?
        var excludedTransitionProblems: Int?

        enum CodingKeys: String, CodingKey {
            case `protocol`, host, path, connected, scanProblems, transitionProblems
            case excludedScanProblems, excludedTransitionProblems
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            `protocol` = c.lenient(.protocol)
            host = c.lenient(.host)
            path = c.lenient(.path)
            connected = c.lenient(.connected)
            scanProblems = c.lenient(.scanProblems)
            transitionProblems = c.lenient(.transitionProblems)
            excludedScanProblems = c.lenient(.excludedScanProblems)
            excludedTransitionProblems = c.lenient(.excludedTransitionProblems)
        }

        /// Failed writes. Scan problems are paths Mutagen skipped on purpose (like an
        /// absolute symlink in portable mode), so they don't turn the dot red.
        var hasProblems: Bool {
            !(transitionProblems ?? []).isEmpty || (excludedTransitionProblems ?? 0) > 0
        }

        var problemLines: [String] {
            ((scanProblems ?? []) + (transitionProblems ?? [])).map { p in
                let path = p.path ?? ""
                return path.isEmpty ? (p.error ?? "problem") : "\(path): \(p.error ?? "problem")"
            }
        }

        /// `host:path` for remote endpoints, just the path for local ones.
        var display: String {
            let p = path ?? "?"
            guard let host, !host.isEmpty else { return p }
            return "\(host):\(p)"
        }
    }

    struct Conflict: Decodable, Equatable {
        var root: String?
    }

    var identifier: String?
    var name: String?
    var status: String?
    var paused: Bool?
    var lastError: String?
    var alpha: Endpoint?
    var beta: Endpoint?
    var conflicts: [Conflict]?
    var excludedConflicts: Int?
    /// Goes up after every cycle that moved something. A change between polls means files crossed.
    var successfulCycles: UInt64?

    enum CodingKeys: String, CodingKey {
        case identifier, name, status, paused, lastError, alpha, beta, conflicts, excludedConflicts, successfulCycles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = c.lenient(.identifier)
        name = c.lenient(.name)
        status = c.lenient(.status)
        paused = c.lenient(.paused)
        lastError = c.lenient(.lastError)
        alpha = c.lenient(.alpha)
        beta = c.lenient(.beta)
        conflicts = c.lenient(.conflicts)
        excludedConflicts = c.lenient(.excludedConflicts)
        successfulCycles = c.lenient(.successfulCycles)
    }

    var id: String { identifier ?? name ?? "" }
    /// Session name without the `ca-` prefix.
    var project: String {
        let n = name ?? "?"
        return n.hasPrefix("ca-") ? String(n.dropFirst(3)) : n
    }
    var statusWord: String { paused == true ? "paused" : (status ?? "unknown") }
    var conflictRoots: [String] { (conflicts ?? []).compactMap(\.root) }
    var error: String? {
        guard let e = lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else { return nil }
        return e
    }

    /// Scan and transition problems from both sides, as `path: error`.
    var problems: [String] { (alpha?.problemLines ?? []) + (beta?.problemLines ?? []) }

    var health: SyncHealth {
        let s = status ?? ""
        if !(conflicts ?? []).isEmpty || (excludedConflicts ?? 0) > 0 { return .problem }
        // Paused on purpose (Mutagen then reports "disconnected"), or still connecting (at
        // launch, or after a drop, maybe with the last error around): amber, not red.
        if paused == true || s.hasPrefix("connecting") { return .busy }
        if error != nil
            || s == "disconnected" || s.hasPrefix("halted")
            || alpha?.hasProblems == true || beta?.hasProblems == true {
            return .problem
        }
        return s == "watching" && paused != true ? .ok : .busy
    }

    var conflictCount: Int { (conflicts ?? []).count + (excludedConflicts ?? 0) }

    /// Mutagen is moving files right now (not just looking for changes).
    var isMoving: Bool {
        let s = status ?? ""
        return paused != true && (s.hasPrefix("staging") || s == "transitioning" || s == "reconciling" || s == "saving")
    }

    /// The portal ring for this session. `crossing` is the monitor's "files moved lately".
    func portal(crossing: Bool) -> PortalRing.State {
        switch health {
        case .problem: return .conflict
        case .busy:
            // Paused or reconnecting is never "crossing", whatever moved just before.
            let stalled = paused == true || (status ?? "").hasPrefix("connecting")
            return !stalled && (isMoving || crossing) ? .crossing : .syncing
        case .ok: return crossing ? .crossing : .steady
        }
    }

    /// The portal's state in a few words, for the popover and tooltips.
    func portalWords(crossing: Bool) -> String {
        let n = conflictCount
        if n > 0 { return "Conflict in \(n) file\(n == 1 ? "" : "s")" }
        let s = status ?? ""
        if paused == true { return "Paused" }
        if s.hasPrefix("connecting") { return "Connecting" }
        if s == "disconnected" { return "Disconnected" }
        if s.hasPrefix("halted") { return "Stopped, needs a look" }
        if error != nil { return "Needs a look" }
        let failed = (alpha?.transitionProblems?.count ?? 0) + (beta?.transitionProblems?.count ?? 0)
            + (alpha?.excludedTransitionProblems ?? 0) + (beta?.excludedTransitionProblems ?? 0)
        if failed > 0 { return "\(failed) file\(failed == 1 ? "" : "s") failed to cross" }
        if isMoving || crossing { return "Files crossing" }
        if s.hasPrefix("scanning") || s == "waiting-for-rescan" { return "Scanning" }
        return s == "watching" ? "In sync" : "Catching up"
    }

    /// Only `ca-*` sessions; anything unparseable is dropped, not fatal.
    static func parse(_ data: Data) -> [SyncSession] {
        struct Item: Decodable {
            var value: SyncSession?
            init(from decoder: Decoder) throws { value = try? SyncSession(from: decoder) }
        }
        let items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        return items.compactMap(\.value).filter { $0.name?.hasPrefix("ca-") == true }
    }
}

private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// Polls Mutagen for `ca-*` sessions (Crossover Portals) every few seconds, only while a window is
/// actually on screen. One for the app, every window shows it. Never starts the
/// Mutagen daemon itself.
@MainActor
final class SyncMonitor: ObservableObject {
    static let shared = SyncMonitor()

    @Published private(set) var installed = false
    @Published private(set) var sessions: [SyncSession] = []
    /// Sessions that moved files in the last `crossingHold` seconds. Worked out on each
    /// poll, so it needs no timer of its own.
    @Published private(set) var crossing: Set<String> = []

    var health: SyncHealth { sessions.map(\.health).max() ?? .ok }

    static let interval: TimeInterval = 3
    static let crossingHold: TimeInterval = 5
    static let lookupInterval: TimeInterval = 60
    static let candidates = ["/opt/homebrew/bin/mutagen", "/usr/local/bin/mutagen",
                             NSHomeDirectory() + "/.local/bin/mutagen"]

    private var windows: () -> [NSWindow] = { [] }
    private var binary: String?
    private var lastLookup = Date.distantPast
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lastCycles: [String: UInt64] = [:]
    private var lastMoved: [String: Date] = [:]

    func start(windows: @escaping () -> [NSWindow]) {
        self.windows = windows
        stop()
        let center = NotificationCenter.default
        // Key and active cover the window being handed over after it first appeared.
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                          NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                                          NSApplication.didBecomeActiveNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLoop() }
            })
        }
        updateLoop()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        loop?.cancel()
        loop = nil
    }

    private var windowVisible: Bool {
        guard !NSApp.isHidden else { return false }
        return windows().contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// Also called when an AppState gets its window, since a launch without focus
    /// fires none of the notifications above.
    func updateLoop() {
        if windowVisible {
            guard loop == nil else { return }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.poll()
                    try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                }
            }
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    private func poll() async {
        if let b = binary, !FileManager.default.isExecutableFile(atPath: b) { binary = nil }
        if binary == nil, Date().timeIntervalSince(lastLookup) >= Self.lookupInterval {
            lastLookup = Date()
            binary = Self.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        guard let binary else {
            if installed { installed = false }
            if !sessions.isEmpty { sessions = [] }
            if !crossing.isEmpty { crossing = [] }
            return
        }
        if !installed { installed = true }
        let found = await Self.fetch(binary: binary)
        guard !Task.isCancelled else { return }
        noteCrossing(found)
        if sessions != found { sessions = found }
    }

    func isCrossing(_ s: SyncSession) -> Bool { crossing.contains(s.id) }

    private func noteCrossing(_ found: [SyncSession]) {
        let now = Date()
        for s in found {
            let cycles = s.successfulCycles ?? 0
            // The first sighting is a baseline, not a crossing.
            if let before = lastCycles[s.id], cycles > before { lastMoved[s.id] = now }
            if s.isMoving { lastMoved[s.id] = now }
            lastCycles[s.id] = cycles
        }
        let ids = Set(found.map(\.id))
        lastCycles = lastCycles.filter { ids.contains($0.key) }
        lastMoved = lastMoved.filter { ids.contains($0.key) && now.timeIntervalSince($0.value) < Self.crossingHold }
        let moving = Set(lastMoved.keys)
        if crossing != moving { crossing = moving }
    }

    /// Runs and parses off the main thread. A failure (daemon not running) is no sessions.
    nonisolated static func fetch(binary: String) async -> [SyncSession] {
        // Through env so the poll can't autostart the daemon.
        let cmd = SpawnCommand(executable: "/usr/bin/env",
                               args: ["MUTAGEN_DISABLE_AUTOSTART=1", binary, "sync", "list", "--template", "{{json .}}"])
        let r = await Runner.run(cmd, timeout: 10)
        guard r.status == 0 else { return [] }
        return await Task.detached(priority: .utility) { SyncSession.parse(Data(r.stdout.utf8)) }.value
    }
}
