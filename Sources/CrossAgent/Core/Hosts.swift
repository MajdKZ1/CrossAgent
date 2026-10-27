import Foundation

struct Host: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case local, ssh }

    var id: String
    var name: String
    var type: Kind
    var target: String?
    var accent: String

    var isLocal: Bool { type == .local }
}

struct HostsFile: Codable {
    var hosts: [Host]
}

enum HostStore {
    /// What a fresh install starts with: just this Mac. Remote machines are added in the
    /// setup sheet or by editing hosts.json.
    static let defaults: [Host] = [
        Host(id: "mac", name: "This Mac", type: .local, target: nil, accent: "#6ea8fe"),
    ]

    /// A Mac plus one ssh machine (alias `pc`), the setup the README walks through.
    /// Tests and demos use it.
    static let example: [Host] = defaults + [
        Host(id: "pc", name: "Linux PC", type: .ssh, target: "pc", accent: "#5fd39a"),
    ]

    #if DEBUG
    /// A demo run's machines. hosts.json is never read or written then, and "PC" is
    /// played by this Mac (see `DemoMode.spawn`).
    static let demo: [Host] = [
        Host(id: "mac", name: "Mac", type: .local, target: nil, accent: "#6ea8fe"),
        Host(id: "pc", name: "PC", type: .ssh, target: "pc", accent: "#5fd39a"),
    ]
    #endif

    /// Accents handed to remote machines in the order they are added.
    static let accents = ["#5fd39a", "#f2a65a", "#c792ea", "#f07178", "#89ddff", "#ffcb6b"]

    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/crossagent", isDirectory: true)
    }

    static var fileURL: URL { configDir.appendingPathComponent("hosts.json") }

    /// Loads hosts.json, writing the defaults first if it does not exist yet. A file
    /// someone else could have written (not ours, group or other writable, a symlink)
    /// is ignored, and so is any host with a bad id or ssh target.
    static func load() -> [Host] {
        #if DEBUG
        if DemoMode.isOn { return demo }
        #endif
        let url = fileURL
        if let problem = PrivateFiles.check(url.path, directory: false), problem != .missing {
            NSLog("CrossAgent: ignoring %@ (%@)", url.path, "\(problem)")
            return defaults
        }
        if let data = try? Data(contentsOf: url) {
            let hosts = parse(data)
            if !hosts.isEmpty { return hosts }
            return defaults
        }
        PrivateFiles.ensureDir(configDir)
        if let data = try? encode(defaults) { try? PrivateFiles.write(data, to: url) }
        return defaults
    }

    /// Valid hosts in a hosts.json body.
    static func parse(_ data: Data) -> [Host] {
        guard let file = try? JSONDecoder().decode(HostsFile.self, from: data) else { return [] }
        return file.hosts.filter(isUsable)
    }

    static func isUsable(_ h: Host) -> Bool {
        isValidID(h.id) && (h.isLocal || isValidTarget(h.target ?? h.id))
    }

    static func encode(_ hosts: [Host]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(HostsFile(hosts: hosts))
    }

    // MARK: Validation

    /// Host ids name tmux sessions and files, so they stay plain.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil
    }

    /// An ssh destination: an alias from ~/.ssh/config, host or user@host. It goes to
    /// ssh as its own argument, so the only things refused are what ssh would read as
    /// an option (a leading `-`) and whitespace or control characters.
    static func isValidTarget(_ target: String) -> Bool {
        !target.isEmpty && target.utf8.count <= 255 && !target.hasPrefix("-")
            && !target.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                    || $0.value == 0x7f
            }
    }

    /// An id from a display name: lowercase, runs of anything else become `-`, at most
    /// 40 characters, and `-2`, `-3`... when `taken` has it already.
    static func makeID(name: String, taken: Set<String>) -> String {
        var base = ""
        for ch in name.lowercased().unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) || ch == "_" {
                base.unicodeScalars.append(ch)
            } else if !base.isEmpty, !base.hasSuffix("-") {
                base += "-"
            }
        }
        while base.hasSuffix("-") { base.removeLast() }
        if base.isEmpty { base = "remote" }
        base = String(base.prefix(40))
        var id = base, n = 2
        while taken.contains(id) {
            let suffix = "-\(n)"
            id = String(base.prefix(40 - suffix.count)) + suffix
            n += 1
        }
        return id
    }

    // MARK: Adding

    enum AddError: Error, Equatable {
        case badID, duplicateID, badTarget, badName, unreadable
    }

    /// The hosts.json body with `host` appended. Keeps every other entry and any keys this
    /// app does not know about. `existing` is the current file, nil if there is none.
    static func adding(_ host: Host, to existing: Data?) throws -> Data {
        guard isValidID(host.id) else { throw AddError.badID }
        guard host.isLocal || isValidTarget(host.target ?? "") else { throw AddError.badTarget }
        guard !host.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw AddError.badName }
        var root: [String: Any] = [:]
        if let existing {
            guard let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw AddError.unreadable
            }
            root = obj
        } else {
            root["hosts"] = try defaults.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        }
        var list = root["hosts"] as? [Any] ?? []
        if list.contains(where: { ($0 as? [String: Any])?["id"] as? String == host.id }) { throw AddError.duplicateID }
        list.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)))
        root["hosts"] = list
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Appends `host` to hosts.json (0600, in a 0700 dir).
    static func add(_ host: Host) throws {
        #if DEBUG
        if DemoMode.isOn { throw AddError.unreadable }
        #endif
        let url = fileURL
        PrivateFiles.ensureDir(configDir)
        let existing: Data?
        switch PrivateFiles.check(url.path, directory: false) {
        case nil: existing = try Data(contentsOf: url)
        case .missing?: existing = nil
        default: throw AddError.unreadable
        }
        try PrivateFiles.write(try adding(host, to: existing), to: url)
    }

    // MARK: First run

    static let setupDismissedKey = "hostSetupDismissed"

    /// Show the setup sheet: nothing remote is set up and it was never skipped.
    static func needsSetup(_ hosts: [Host], defaults store: UserDefaults = AppDefaults.store) -> Bool {
        hosts.allSatisfy(\.isLocal) && !store.bool(forKey: setupDismissedKey)
    }
}

/// The setup sheet's Test button: can we reach a machine, and does it have tmux and claude.
enum HostProbe {
    struct Result: Equatable {
        var reachable: Bool
        var tmux: Bool = false
        var claude: Bool = false
        var error: String = ""
    }

    /// Batch mode so a password or host key prompt fails fast instead of hanging. A login
    /// shell with the same PATH as panes get, so it finds claude where a pane would.
    static func command(target: String) -> SpawnCommand {
        precondition(HostStore.isValidTarget(target))
        let script = CommandBuilder.pathPrefix + "command -v tmux; command -v claude; true"
        return SpawnCommand(executable: "/usr/bin/ssh",
                            args: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] + SSH.baseOptions
                                + ["--", target, "exec $SHELL -lc " + CommandBuilder.shellQuote(script)])
    }

    static func parse(status: Int32, stdout: String, stderr: String) -> Result {
        guard status == 0 else {
            let err = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? "ssh exited with \(status)"
            return Result(reachable: false, error: String(err.prefix(160)))
        }
        let lines = stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func has(_ name: String) -> Bool {
            lines.contains { $0 == name || $0.hasSuffix("/" + name) || $0.hasPrefix("alias \(name)=") }
        }
        return Result(reachable: true, tmux: has("tmux"), claude: has("claude"))
    }

    static func run(target: String) async -> Result {
        let r = await Runner.run(command(target: target), timeout: 25)
        return parse(status: r.status, stdout: r.stdout, stderr: r.stderr)
    }
}
