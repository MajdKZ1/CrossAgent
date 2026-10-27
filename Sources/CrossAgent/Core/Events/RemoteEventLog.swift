import Foundation

/// Remote worker events the project followers saw, per project slug, so a session's Live
/// view (fed by its transcript, which never shows the PC side) can draw them too, also
/// when it opens later.
@MainActor
enum RemoteEventLog {
    struct Entry {
        var seq: Int
        var event: AgentEvent
    }

    static let keep = 1000
    private static var paths: [String: [String: String]] = [:]
    private static var log: [String: [Entry]] = [:]
    private static var seq = 0

    /// A project whose events get logged, with its folder per host.
    static func register(project: String, projectPaths: [String: String]) {
        guard !project.isEmpty else { return }
        paths[project] = projectPaths
    }

    /// Logs the role "remote" events of `project`, then hands them to open session feeds.
    static func add(_ events: [AgentEvent], project: String) {
        let mine = events.filter { $0.role == "remote" && $0.project == project }
        guard !project.isEmpty, !mine.isEmpty else { return }
        var l = log[project] ?? []
        for e in mine {
            seq += 1
            l.append(Entry(seq: seq, event: e))
        }
        if l.count > keep { l.removeFirst(l.count - keep) }
        log[project] = l
        SessionFeed.pullRemoteEvents()
    }

    /// The registered project a session's cwd is in.
    static func project(host: String, cwd: String) -> String? {
        let probe = AgentEvent(ts: 0, ev: "", host: host, cwd: cwd)
        return paths.first { !$0.value.isEmpty && AgentGraph.belongs(probe, project: $0.key, projectPaths: $0.value) }?.key
    }

    static func entries(project: String, after: Int) -> [Entry] {
        (log[project] ?? []).filter { $0.seq > after }
    }
}
