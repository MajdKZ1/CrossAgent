import Foundation

extension DemoMode {
    /// Arguments that go right after `tmux` for anything that runs tmux directly instead of
    /// through `CommandBuilder` (which handles the demo itself).
    static var tmuxArgs: [String] { isOn ? ["-L", tmuxSocket] : [] }
}

#if DEBUG
/// Where a demo run lives and how its commands run. Every command for every host, the
/// "remote" one included, runs here on this Mac in a clean environment: a throwaway
/// HOME, a PATH whose `tmux` always talks to the ca-demo server and whose `claude` is a
/// mock, and plain bash with no profile. See scripts/demo/.
extension DemoMode {
    /// Scratch space: the fake home (with its own empty ~/.claude) and saved project state.
    static let root = URL(fileURLWithPath: "/tmp/crossagent-demo", isDirectory: true)
    static var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    static var stateDir: URL { root.appendingPathComponent("state", isDirectory: true) }

    /// scripts/demo in the checkout this build came from, or CROSSAGENT_DEMO_DIR.
    static let scriptsDir: URL = {
        if let dir = ProcessInfo.processInfo.environment["CROSSAGENT_DEMO_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("scripts/demo", isDirectory: true)
    }()

    static var binDir: URL { scriptsDir.appendingPathComponent("bin", isDirectory: true) }

    /// The one project a demo opens, and the made up recents listed next to it.
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects", isDirectory: true)
    }
    static var projectURL: URL { projectsDir.appendingPathComponent("demo", isDirectory: true) }

    static func recents(now: Date = Date()) -> [RecentProject] {
        [("demo", 0.0), ("api", 26 * 3600.0), ("site", 3 * 86400.0)].map { name, ago in
            RecentProject(path: projectsDir.appendingPathComponent(name).path, name: name,
                          lastOpened: now.addingTimeInterval(-ago - 120))
        }
    }

    static func isDemoProject(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path == projectURL.standardizedFileURL.path
    }

    /// Bash prompt in every demo shell: `demo:~/Projects/demo$ `.
    static let prompt = #"\[\e[32m\]demo\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]$ "#

    /// Runs `script` the demo way: local, clean env, no profile. Used for every host.
    static func spawn(script: String) -> SpawnCommand {
        let bin = binDir.path
        let env = [
            "HOME=" + home.path, "USER=demo", "LOGNAME=demo",
            "PATH=\(bin):/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL=\(bin)/demo-shell", "PS1=" + prompt, "DEMO_PS1=" + prompt, "HISTFILE=/dev/null",
            "TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8",
            "BASH_SILENCE_DEPRECATION_WARNING=1",
        ]
        return SpawnCommand(executable: "/usr/bin/env",
                            args: ["-i"] + env + ["/bin/bash", "--noprofile", "--norc", "-c", script])
    }

    /// At launch, before anything reads defaults or spawns: empties the demo defaults
    /// and state, makes the fake home and the demo project folder.
    static func prepare() {
        guard isOn else { return }
        AppDefaults.store.removePersistentDomain(forName: defaultsSuite)
        let fm = FileManager.default
        try? fm.removeItem(at: stateDir)
        for dir in [stateDir, home.appendingPathComponent("Projects/demo"), home.appendingPathComponent(".claude"),
                    projectURL] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.isExecutableFile(atPath: binDir.appendingPathComponent("tmux").path) {
            NSLog("CrossAgent demo: %@ is missing, panes will not start (set CROSSAGENT_DEMO_DIR)", binDir.path)
        }
    }
}
#endif
