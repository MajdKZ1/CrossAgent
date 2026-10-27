import CryptoKit
import Foundation

/// A project is a folder on this Mac. Its PC copy lives at the same path relative to
/// home, following the same rules as `pc_dir()` in skills/crossagent/scripts/ca.
struct Project: Codable, Hashable, Identifiable {
    /// Absolute, standardized folder path on the Mac.
    var path: String
    /// Folder name, shown in the UI.
    var name: String
    /// ProjectSlug of the name, used in tmux session names.
    var slug: String
    /// Folder on the PC, relative to the PC user's home.
    var pcRelativePath: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Reads `<folder>/.crossagent/project` for a `pc_dir=` override.
    init(url: URL, home: String = NSHomeDirectory()) {
        let path = url.standardizedFileURL.path
        let conf = try? String(contentsOfFile: path + "/.crossagent/project", encoding: .utf8)
        self.init(path: path, home: home, config: conf)
    }

    /// Pure version for tests: `config` is the contents of `.crossagent/project`, if any.
    init(path: String, home: String, config: String?) {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        self.path = p
        name = (p as NSString).lastPathComponent
        slug = ProjectSlug.make(name)
        pcRelativePath = Self.pcDir(root: p, home: home, config: config)
    }

    /// `NAME` in the ca script: basename with anything outside `A-Za-z0-9._-` turned into `_`.
    static func safeName(_ basename: String) -> String {
        String(String.UnicodeScalarView(basename.unicodeScalars.map { ch in
            isAlnum(ch) || ch == "." || ch == "_" || ch == "-" ? ch : "_"
        }))
    }

    /// `pc_dir()` in the ca script: `pc_dir=` wins, else the path under home, else
    /// `crossagent/projects/<NAME>`.
    static func pcDir(root: String, home: String, config: String?) -> String {
        if let config {
            for line in config.split(separator: "\n", omittingEmptySubsequences: false)
            where line.hasPrefix("pc_dir=") {
                let v = String(line.dropFirst("pc_dir=".count))
                if !v.isEmpty { return v }
                break
            }
        }
        var h = home
        while h.count > 1, h.hasSuffix("/") { h.removeLast() }
        if root.hasPrefix(h + "/"), root.count > h.count + 1 { return String(root.dropFirst(h.count + 1)) }
        return "crossagent/projects/" + safeName((root as NSString).lastPathComponent)
    }

    /// Mutagen session name, `sess()` in the ca script.
    var syncSessionName: String { Self.syncSessionName(name: name) }

    static func syncSessionName(name: String) -> String {
        var out = ""
        for ch in safeName(name).unicodeScalars {
            if isAlnum(ch) {
                out.unicodeScalars.append(ch)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        if out.hasPrefix("-") { out.removeFirst() }
        if out.hasSuffix("-") { out.removeLast() }
        return "ca-" + out
    }

    /// Where panes on `host` start. On the Mac an absolute path; on an ssh host
    /// `$HOME/<pcRelativePath>`, left for the remote login shell to expand
    /// (`CommandBuilder.shellPath` quotes it that way).
    func cwd(for host: Host) -> String {
        host.isLocal ? path : "$HOME/" + pcRelativePath
    }

    private static func isAlnum(_ ch: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(ch) || ("A"..."Z").contains(ch) || ("0"..."9").contains(ch)
    }
}

// MARK: - Per project state

struct SavedPane: Codable, Equatable {
    var hostId: String
    var mode: PaneMode
    var session: String
}

struct OrchestratorState: Codable, Equatable {
    var hostId: String
    var session: String
    var enabled: Bool
}

/// What a project remembers between launches. Every key is optional on disk so older
/// or hand edited files still load.
struct ProjectState: Codable, Equatable {
    var panes: [SavedPane] = []
    /// "panes", "station" or "orchestrator".
    var mode: String?
    var orchestrator: OrchestratorState?
    var nodePositions: [String: CGPoint] = [:]
    var finishedNodes: [AgentNode]?

    init(panes: [SavedPane] = [], mode: String? = nil, orchestrator: OrchestratorState? = nil,
         nodePositions: [String: CGPoint] = [:], finishedNodes: [AgentNode]? = nil) {
        self.panes = panes
        self.mode = mode
        self.orchestrator = orchestrator
        self.nodePositions = nodePositions
        self.finishedNodes = finishedNodes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panes = (try? c.decodeIfPresent([SavedPane].self, forKey: .panes)) ?? []
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        orchestrator = try? c.decodeIfPresent(OrchestratorState.self, forKey: .orchestrator)
        nodePositions = (try? c.decodeIfPresent([String: CGPoint].self, forKey: .nodePositions)) ?? [:]
        finishedNodes = try? c.decodeIfPresent([AgentNode].self, forKey: .finishedNodes)
    }
}

// MARK: - Store

struct RecentProject: Codable, Hashable, Identifiable {
    var path: String
    var name: String
    var lastOpened: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Recents and the last open project in UserDefaults, per project state as JSON files.
struct ProjectStore {
    static let recentsKey = "recentProjects.v1"
    static let lastProjectKey = "lastProject.v1"
    static let maxRecents = 10

    var defaults: UserDefaults = .standard
    var stateDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CrossAgent/projects", isDirectory: true)

    /// Newest first. Folders that no longer exist are dropped.
    func recents() -> [RecentProject] {
        let all = storedRecents()
        let alive = all.filter { Self.folderExists($0.path) }
        if alive.count != all.count { saveRecents(alive) }
        return alive
    }

    func noteOpened(_ project: Project, at date: Date = Date()) {
        var list = storedRecents().filter { $0.path != project.path }
        list.insert(RecentProject(path: project.path, name: project.name, lastOpened: date), at: 0)
        saveRecents(Array(list.prefix(Self.maxRecents)))
    }

    func removeRecent(path: String) {
        saveRecents(storedRecents().filter { $0.path != path })
    }

    var lastProjectPath: String? {
        get { defaults.string(forKey: Self.lastProjectKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.lastProjectKey) }
    }

    func stateURL(for project: Project) -> URL {
        let hash = SHA256.hash(data: Data(project.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return stateDir.appendingPathComponent("\(project.slug)-\(hash.prefix(8)).json")
    }

    /// Empty state when the file is missing or unreadable.
    func loadState(for project: Project) -> ProjectState {
        guard let data = try? Data(contentsOf: stateURL(for: project)),
              let state = try? JSONDecoder().decode(ProjectState.self, from: data) else { return ProjectState() }
        return state
    }

    func saveState(_ state: ProjectState, for project: Project) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? data.write(to: stateURL(for: project), options: .atomic)
    }

    static func folderExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func storedRecents() -> [RecentProject] {
        guard let data = defaults.data(forKey: Self.recentsKey),
              let list = try? JSONDecoder().decode([RecentProject].self, from: data) else { return [] }
        return list.sorted { $0.lastOpened > $1.lastOpened }
    }

    private func saveRecents(_ list: [RecentProject]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.recentsKey) }
    }
}
