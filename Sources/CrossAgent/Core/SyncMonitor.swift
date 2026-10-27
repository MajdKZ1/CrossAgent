import AppKit

/// How a sync session (or all of them) is doing, for the top bar dot.
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

    enum CodingKeys: String, CodingKey {
        case identifier, name, status, paused, lastError, alpha, beta, conflicts, excludedConflicts
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
        if !(conflicts ?? []).isEmpty || (excludedConflicts ?? 0) > 0 || error != nil
            || s == "disconnected" || s.hasPrefix("halted")
            || alpha?.hasProblems == true || beta?.hasProblems == true {
            return .problem
        }
        return s == "watching" && paused != true ? .ok : .busy
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

/// Polls Mutagen for `ca-*` sync sessions every few seconds, only while the main window
/// is actually on screen. Never starts the Mutagen daemon itself.
@MainActor
final class SyncMonitor: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var sessions: [SyncSession] = []

    var health: SyncHealth { sessions.map(\.health).max() ?? .ok }

    static let interval: TimeInterval = 3
    static let lookupInterval: TimeInterval = 60
    static let candidates = ["/opt/homebrew/bin/mutagen", "/usr/local/bin/mutagen",
                             NSHomeDirectory() + "/.local/bin/mutagen"]

    private var window: () -> NSWindow? = { nil }
    private var binary: String?
    private var lastLookup = Date.distantPast
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func start(window: @escaping () -> NSWindow?) {
        self.window = window
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
        guard !NSApp.isHidden, let w = window() else { return false }
        return w.isVisible && w.occlusionState.contains(.visible)
    }

    private func updateLoop() {
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
            return
        }
        if !installed { installed = true }
        let found = await Self.fetch(binary: binary)
        guard !Task.isCancelled else { return }
        if sessions != found { sessions = found }
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
