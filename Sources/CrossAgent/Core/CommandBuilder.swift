import Foundation

enum PaneMode: String, Codable, CaseIterable {
    case claude, shell

    var label: String { self == .claude ? "Claude" : "Shell" }
}

enum SessionName {
    static func isValid(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    /// Any tmux session name we can attach to by exact match: tmux itself bans `:` and
    /// `.`, control characters are refused, everything else gets shell quoted.
    static func isAttachable(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128
            && !name.unicodeScalars.contains { $0 == ":" || $0 == "." || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// First `ca-<slug>-<host>-<n>` not in `used`.
    static func nextFree(slug: String, host: String, used: Set<String>) -> String {
        var n = 1
        while used.contains(CASessionName.make(slug: slug, host: host, task: "\(n)")) { n += 1 }
        return CASessionName.make(slug: slug, host: host, task: "\(n)")
    }
}

/// Executable plus argv for a pane. Pure, so it is easy to test.
struct SpawnCommand: Equatable {
    var executable: String
    var args: [String]
}

enum CommandBuilder {
    /// claude installs into one of these. A login non-interactive shell often
    /// misses them because they are added in .zshrc / .bashrc.
    static let pathPrefix = #"export PATH="$HOME/.local/bin:$HOME/.claude/local:$PATH"; "#

    /// Marks a tmux client as CrossAgent's, see `SessionClients`.
    static let clientEnvKey = "CROSSAGENT_CLIENT"
    static let clientEnv = "export \(clientEnvKey)=1; "

    /// Spec script plus `set -q status off` for this session only: the pane header
    /// already shows the session, and tmux's bright status bar clashes with the UI.
    /// Also turns on focus-events, which Claude Code asks for, and mouse for this session,
    /// so the wheel scrolls tmux's history (the pane keeps clicks local, see PaneTerminalView).
    /// No prefix key for this session and clipboard passthrough, the same as the claude
    /// wrapper's sessions, so a session feels the same wherever it was started.
    ///
    /// The tmux client gets `CROSSAGENT_CLIENT=1` in its environment, so discovery can
    /// tell CrossAgent's own clients from other places viewing the same session.
    ///
    /// `cwd` is where a new session starts (`tmux new -c`, or `cd` without tmux). A
    /// leading `$HOME/` is left for the host's shell to expand, see `shellPath`.
    /// `env` goes to the session with `tmux new -e`, or is exported without tmux. Both
    /// only matter when the session is created; an existing one keeps its own.
    /// `attachOnly` attaches to an existing session (`tmux attach -t '=NAME'`) and never
    /// creates one; `mode` is ignored then, and any tmux name `isAttachable` takes works.
    /// `program` replaces `claude` in claude mode (a shell line, like `SessionResume.script`).
    static func script(mode: PaneMode, session: String, cwd: String? = nil, env: [String: String] = [:],
                       attachOnly: Bool = false, program: String? = nil) -> String {
        precondition(attachOnly ? SessionName.isAttachable(session) : SessionName.isValid(session))
        let opts = " \\; set -q status off \\; set -q mouse on \\; set -sq focus-events on"
            + " \\; set -q prefix None \\; set -q prefix2 None \\; set -sq set-clipboard on"
        if attachOnly {
            return pathPrefix + "if command -v tmux >/dev/null 2>&1; then \(clientEnv)exec tmux attach -t \(shellQuote("=" + session))\(opts); else echo 'tmux is not installed here' >&2; exit 1; fi"
        }
        var newArgs = "-A -s \(session)"
        var fallback = ""
        if let cwd, !cwd.isEmpty {
            let dir = shellPath(cwd)
            newArgs += " -c " + dir
            fallback += "cd \(dir) 2>/dev/null; "
        }
        for key in env.keys.sorted() where isEnvKey(key) {
            let kv = shellQuote("\(key)=\(env[key]!)")
            newArgs += " -e " + kv
            fallback += "export \(kv); "
        }
        switch mode {
        case .claude:
            let run = program.map(shellQuote) ?? "claude"
            let direct = program.map { "exec sh -c " + shellQuote($0) } ?? "exec claude"
            return pathPrefix + "if command -v tmux >/dev/null 2>&1; then \(clientEnv)exec tmux new \(newArgs) \(run)\(opts); else \(fallback)\(direct); fi"
        case .shell:
            return pathPrefix + "if command -v tmux >/dev/null 2>&1; then \(clientEnv)exec tmux new \(newArgs)\(opts); else \(fallback)exec \"$SHELL\" -l; fi"
        }
    }

    static func command(host: Host, mode: PaneMode, session: String, cwd: String? = nil, env: [String: String] = [:],
                        attachOnly: Bool = false, program: String? = nil, localShell: String = LocalShell.path) -> SpawnCommand {
        let s = script(mode: mode, session: session, cwd: cwd, env: env, attachOnly: attachOnly, program: program)
        switch host.type {
        case .local:
            return SpawnCommand(executable: localShell, args: ["-lc", s])
        case .ssh:
            let remote = "exec $SHELL -lc " + shellQuote(s)
            return SpawnCommand(executable: "/usr/bin/ssh",
                                args: ["-tt"] + SSH.baseOptions + [host.target ?? host.id, remote])
        }
    }

    /// Quotes a path for sh, leaving a leading `$HOME` (or `~`) to the shell:
    /// `$HOME/a b` becomes `"$HOME"/'a b'`.
    static func shellPath(_ path: String) -> String {
        for prefix in ["$HOME", "~"] where path == prefix || path.hasPrefix(prefix + "/") {
            let rest = String(path.dropFirst(prefix.count + 1))
            return rest.isEmpty ? "\"$HOME\"" : "\"$HOME\"/" + shellQuote(rest)
        }
        return shellQuote(path)
    }

    static func isEnvKey(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// Command that kills a tmux session on a host, run without a PTY. `=` makes tmux
    /// match the name exactly; a bare `-t ca-pc-1` would kill `ca-pc-10` if `ca-pc-1` were gone.
    /// Quoted because zsh expands an unquoted `=word` to a command path.
    static func killCommand(host: Host, session: String) -> SpawnCommand {
        precondition(SessionName.isValid(session))
        return oneShot(host: host, script: "tmux kill-session -t '=\(session)'")
    }

    /// Runs a short script in a login shell on the host (no PTY).
    static func oneShot(host: Host, script: String, localShell: String = LocalShell.path) -> SpawnCommand {
        let s = pathPrefix + script
        switch host.type {
        case .local:
            return SpawnCommand(executable: localShell, args: ["-lc", s])
        case .ssh:
            return SpawnCommand(executable: "/usr/bin/ssh",
                                args: ["-T", "-o", "BatchMode=yes"] + SSH.baseOptions + [host.target ?? host.id, "exec $SHELL -lc " + shellQuote(s)])
        }
    }

    /// POSIX single quote escaping.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum LocalShell {
    static let path: String = {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }()
}

enum SSH {
    /// Keepalive per spec, plus client side connection sharing. The tunnel to the
    /// PC costs about 5 s per fresh connect and under 1 s once a master exists.
    static let baseOptions: [String] = [
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=/tmp/crossagent-%C",
        "-o", "ControlPersist=10m",
    ]
}
