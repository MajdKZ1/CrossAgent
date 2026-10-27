import Foundation

/// The event pipeline for one project: hook script on every host, our hooks in the
/// project's .claude/settings.local.json, one follower per host feeding `graph`.
/// Takes plain values so it does not depend on the Project type.
@MainActor
final class OrchestratorController: ObservableObject {
    let slug: String
    let macPath: String
    let pcRelativePath: String
    private(set) var hosts: [Host]
    let graph: AgentGraph

    /// Our hooks are in the project's local settings on this Mac.
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRunning = false

    private var followers: [EventFollower] = []
    private var ticker: Timer?

    init(slug: String, macPath: String, pcRelativePath: String, hosts: [Host], graph: AgentGraph) {
        self.slug = slug
        self.macPath = macPath
        self.pcRelativePath = pcRelativePath
        self.hosts = hosts
        self.graph = graph
        graph.hosts = hosts
        self.isEnabled = HookInstaller.hooksInstalled(projectPath: macPath)
    }

    /// Host id to project folder, for matching events by cwd.
    var projectPaths: [String: String] {
        var paths: [String: String] = [:]
        for h in hosts {
            if h.isLocal { paths[h.id] = macPath } else if !pcRelativePath.isEmpty { paths[h.id] = pcRelativePath }
        }
        return paths
    }

    /// Installs the hook script on every host, our hooks in the project's settings on
    /// every host, then starts following. Returns the ids of hosts that failed.
    /// `skipSettings` are ssh hosts that get the script but not the project hooks
    /// (their project folder does not exist yet, and this must not create it).
    @discardableResult
    func enable(skipSettings: Set<String> = []) async -> [String] {
        // Demo: no hook script, no settings, nothing followed. Stories feed the graph.
        if DemoMode.isOn {
            isEnabled = true
            start()
            return []
        }
        var failed: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for h in hosts {
                let rel = pcRelativePath
                let skip = skipSettings.contains(h.id)
                group.addTask {
                    var ok = await HookInstaller.installHookScript(on: h)
                    if !h.isLocal, ok, !rel.isEmpty, !skip {
                        ok = await HookInstaller.installHooks(on: h, relativePath: rel)
                    }
                    return (h.id, ok)
                }
            }
            for await (id, ok) in group where !ok { failed.append(id) }
        }
        do { try HookInstaller.installHooks(projectPath: macPath) } catch { failed.append("mac-settings") }
        isEnabled = HookInstaller.hooksInstalled(projectPath: macPath)
        start()
        return failed
    }

    /// Removes only our hooks (on every host) and stops following.
    func disable() async {
        stop()
        if DemoMode.isOn {
            isEnabled = false
            return
        }
        try? HookInstaller.removeHooks(projectPath: macPath)
        let rel = pcRelativePath
        if !rel.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for h in hosts where !h.isLocal {
                    group.addTask { _ = await HookInstaller.removeHooks(on: h, relativePath: rel) }
                }
            }
        }
        isEnabled = HookInstaller.hooksInstalled(projectPath: macPath)
    }

    /// Starts the followers and the idle ticker. Safe to call twice.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        if DemoMode.isOn { return }
        let slug = slug
        let paths = projectPaths
        RemoteEventLog.register(project: slug, projectPaths: paths)
        followers = hosts.map { h in
            EventFollower(host: h) { [weak graph] events in
                graph?.apply(events, project: slug, projectPaths: paths)
                RemoteEventLog.add(events, project: slug)
            }
        }
        for f in followers { f.start() }
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak graph] _ in
            MainActor.assumeIsolated { graph?.tick(now: Date()) }
        }
    }

    /// New host list at runtime. The graph learns it right away. While following, hosts
    /// that are gone lose their follower and new ones get the hook script and a follower;
    /// project hooks on a new host come with the next enable, like any host whose folder
    /// wasn't there yet.
    func setHosts(_ new: [Host]) {
        guard new != hosts else { return }
        let old = hosts
        hosts = new
        graph.hosts = new
        guard isRunning, !DemoMode.isOn else { return }
        let ids = Set(new.map(\.id))
        followers.removeAll { f in
            let gone = !ids.contains(f.host.id) || new.first(where: { $0.id == f.host.id }) != f.host
            if gone { f.stop() }
            return gone
        }
        let slug = slug
        let paths = projectPaths
        RemoteEventLog.register(project: slug, projectPaths: paths)
        for h in new where old.first(where: { $0.id == h.id }) != h {
            let f = EventFollower(host: h) { [weak graph] events in
                graph?.apply(events, project: slug, projectPaths: paths)
                RemoteEventLog.add(events, project: slug)
            }
            followers.append(f)
            if isEnabled, !h.isLocal {
                Task { _ = await HookInstaller.installHookScript(on: h); f.start() }
            } else {
                f.start()
            }
        }
    }

    func stop() {
        for f in followers { f.stop() }
        followers = []
        ticker?.invalidate()
        ticker = nil
        isRunning = false
    }
}
