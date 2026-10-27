import Foundation

/// Adds and removes the CrossAgent hook in a project's `.claude/settings.local.json`.
/// The JSON edits are pure so they are easy to test; everything else in the file
/// (other hooks, permissions, env, ...) is left alone.
enum HookInstaller {
    /// Where the hook script lives on every host.
    static let scriptRelativePath = ".crossagent/bin/crossagent-hook.py"
    /// The command Claude Code runs. Our entries are recognised by the script path.
    static let command = #"python3 -I "$HOME/.crossagent/bin/crossagent-hook.py""#
    static let marker = "/.crossagent/bin/crossagent-hook.py"

    /// Hook events we listen to. All checked against Claude Code 2.1.311.
    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SubagentStart",
        "SubagentStop", "PermissionRequest", "PermissionDenied", "TaskCompleted", "TeammateIdle",
    ]
    /// Events whose matcher is a tool name. The rest take no matcher.
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"]

    // MARK: Pure JSON edits

    /// Returns the settings with our hooks added. Idempotent. Bad or missing input
    /// starts from an empty object.
    static func install(into settingsJSON: Data?) -> Data {
        var root = parse(settingsJSON) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var groups = stripped(hooks[ev] as? [Any] ?? [])
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "async": true, "timeout": 10] as [String: Any]],
            ]
            if toolEvents.contains(ev) { group["matcher"] = "*" }
            groups.append(group)
            hooks[ev] = groups
        }
        root["hooks"] = hooks
        return serialize(root)
    }

    /// Returns the settings without our hooks, or nil when nothing else is left
    /// (meaning: delete the file).
    static func remove(from settingsJSON: Data) -> Data? {
        guard var root = parse(settingsJSON) else { return settingsJSON }
        if var hooks = root["hooks"] as? [String: Any] {
            for (ev, value) in hooks {
                guard let groups = value as? [Any] else { continue }
                let left = stripped(groups)
                hooks[ev] = left.isEmpty ? nil : left
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
        }
        return root.isEmpty ? nil : serialize(root)
    }

    /// True when the settings carry at least one of our hooks.
    static func isInstalled(in settingsJSON: Data?) -> Bool {
        guard let hooks = parse(settingsJSON)?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [Any] ?? []).contains { isOurs(group: $0) }
        }
    }

    /// Drops our command hooks from a list of matcher groups, and any group left empty by that.
    private static func stripped(_ groups: [Any]) -> [Any] {
        groups.compactMap { g -> Any? in
            guard var group = g as? [String: Any], let list = group["hooks"] as? [Any] else { return g }
            let keep = list.filter { !isOurs(hook: $0) }
            if keep.count == list.count { return g }
            if keep.isEmpty { return nil }
            group["hooks"] = keep
            return group
        }
    }

    private static func isOurs(hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    private static func isOurs(group: Any) -> Bool {
        ((group as? [String: Any])?["hooks"] as? [Any] ?? []).contains { isOurs(hook: $0) }
    }

    private static func parse(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func serialize(_ obj: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    // MARK: Files

    static func settingsURL(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appendingPathComponent(".claude/settings.local.json")
    }

    static func installHooks(projectPath: String) throws {
        let url = settingsURL(projectPath: projectPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try install(into: try? Data(contentsOf: url)).write(to: url, options: .atomic)
    }

    static func removeHooks(projectPath: String) throws {
        let url = settingsURL(projectPath: projectPath)
        guard let data = try? Data(contentsOf: url) else { return }
        if let out = remove(from: data) {
            if out != data { try out.write(to: url, options: .atomic) }
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func hooksInstalled(projectPath: String) -> Bool {
        isInstalled(in: try? Data(contentsOf: settingsURL(projectPath: projectPath)))
    }

    /// Same edits on an ssh host. `relativePath` is the project folder under the remote $HOME.
    static func installHooks(on host: Host, relativePath: String) async -> Bool {
        await editRemote(host: host, relativePath: relativePath) { install(into: $0) }
    }

    static func removeHooks(on host: Host, relativePath: String) async -> Bool {
        await editRemote(host: host, relativePath: relativePath) { data in data.flatMap(remove(from:)) }
    }

    private static func editRemote(host: Host, relativePath: String, _ edit: (Data?) -> Data?) async -> Bool {
        let dir = CommandBuilder.shellQuote(relativePath.isEmpty ? "." : relativePath) + "/.claude"
        let read = await EventShell.run(CommandBuilder.oneShot(host: host, script: "cd \"$HOME\" && cat \(dir)/settings.local.json 2>/dev/null || true"))
        guard read.status == 0 else { return false }
        let current = read.stdout.isEmpty ? nil : read.stdout
        let next = edit(current)
        if next == current { return true }
        let script: String
        if next == nil {
            script = "cd \"$HOME\" && rm -f \(dir)/settings.local.json"
        } else {
            script = "cd \"$HOME\" && mkdir -p \(dir) && cat > \(dir)/settings.local.json.ca-tmp && mv \(dir)/settings.local.json.ca-tmp \(dir)/settings.local.json"
        }
        return await EventShell.run(CommandBuilder.oneShot(host: host, script: script), input: next ?? Data()).status == 0
    }

    // MARK: Hook script

    /// crossagent-hook.py from the .app, or from the SwiftPM resource bundle next to
    /// a bare executable. Same lookup as the app icon; never Bundle.module.
    static func bundledScriptURL() -> URL? {
        // Next to the binary for swift run, in Contents/Resources inside the .app (bundle.sh puts it there).
        let dirs = [Bundle.main.executableURL?.deletingLastPathComponent(), Bundle.main.resourceURL]
        let bundles = dirs.compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent("CrossAgent_CrossAgent.bundle")) } }
        return Bundle.main.url(forResource: "crossagent-hook", withExtension: "py")
            ?? bundles.lazy.compactMap { $0.url(forResource: "crossagent-hook", withExtension: "py") }.first
    }

    /// Writes the hook script to ~/.crossagent/bin on the host. True on success.
    @discardableResult
    static func installHookScript(on host: Host, script: Data? = nil) async -> Bool {
        guard let body = script ?? bundledScriptURL().flatMap({ try? Data(contentsOf: $0) }) else { return false }
        if host.isLocal {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(scriptRelativePath)
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? Data(contentsOf: url)) == body { return true }
                try body.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                return true
            } catch {
                return false
            }
        }
        let path = "~/" + scriptRelativePath
        let script = "mkdir -p ~/.crossagent/bin && cat > \(path).tmp && chmod 755 \(path).tmp && mv \(path).tmp \(path)"
        return await EventShell.run(CommandBuilder.oneShot(host: host, script: script), input: body).status == 0
    }
}

/// Like Runner, but feeds stdin. Kept here so Runner stays untouched.
enum EventShell {
    static func run(_ cmd: SpawnCommand, input: Data? = nil, timeout: TimeInterval = 20) async -> (status: Int32, stdout: Data) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(cmd, input: input, timeout: timeout))
            }
        }
    }

    static func runSync(_ cmd: SpawnCommand, input: Data?, timeout: TimeInterval) -> (status: Int32, stdout: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.executable)
        p.arguments = cmd.args
        let inPipe = Pipe(), out = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        if let input {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return (p.terminationStatus, data)
    }
}
