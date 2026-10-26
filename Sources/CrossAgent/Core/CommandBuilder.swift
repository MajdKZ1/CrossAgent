import Foundation

enum PaneMode: String, Codable, CaseIterable {
    case claude, shell

    var label: String { self == .claude ? "Claude" : "Shell" }
}

enum SessionName {
    static func isValid(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil
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

    static func script(mode: PaneMode, session: String) -> String {
        precondition(SessionName.isValid(session))
        switch mode {
        case .claude:
            return pathPrefix + "if command -v tmux >/dev/null 2>&1; then exec tmux new -A -s \(session) claude; else exec claude; fi"
        case .shell:
            return pathPrefix + "if command -v tmux >/dev/null 2>&1; then exec tmux new -A -s \(session); else exec \"$SHELL\" -l; fi"
        }
    }

    static func command(host: Host, mode: PaneMode, session: String, localShell: String = LocalShell.path) -> SpawnCommand {
        let s = script(mode: mode, session: session)
        switch host.type {
        case .local:
            return SpawnCommand(executable: localShell, args: ["-lc", s])
        case .ssh:
            let remote = "exec $SHELL -lc " + shellQuote(s)
            return SpawnCommand(executable: "/usr/bin/ssh",
                                args: ["-tt"] + SSH.baseOptions + [host.target ?? host.id, remote])
        }
    }

    /// Command that kills a tmux session on a host, run without a PTY.
    static func killCommand(host: Host, session: String) -> SpawnCommand {
        precondition(SessionName.isValid(session))
        return oneShot(host: host, script: "tmux kill-session -t \(session)")
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
