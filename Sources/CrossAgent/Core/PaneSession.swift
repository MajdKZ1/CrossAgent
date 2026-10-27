import AppKit
import SwiftTerm

/// One pane: a host, a mode, a tmux session, and the live terminal view.
@MainActor
final class PaneSession: ObservableObject, Identifiable {
    enum State: Equatable { case connecting, live, exited(Int32?) }

    let id = UUID()
    let host: Host
    let mode: PaneMode
    let session: String
    /// Where a new tmux session starts, see `CommandBuilder.script`.
    let cwd: String?
    /// Extra env for a new tmux session, like CROSSAGENT_PROJECT.
    let env: [String: String]
    /// Attach to an existing tmux session only, never create one.
    let attachOnly: Bool
    let terminal: PaneTerminalView
    let startedAt = Date()

    @Published private(set) var state: State = .connecting
    @Published private(set) var title: String = ""
    /// Last time the process printed anything. Not published, read on demand.
    private(set) var lastOutput = Date()

    private var delegateBox: Delegate?

    init(host: Host, mode: PaneMode, session: String, cwd: String? = nil, env: [String: String] = [:],
         attachOnly: Bool = false) {
        self.host = host
        self.mode = mode
        self.session = session
        self.cwd = cwd
        self.env = env
        self.attachOnly = attachOnly
        terminal = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        Theme.apply(to: terminal)
        TerminalAppearance.apply(to: terminal)
        terminal.configure()
        let box = Delegate(owner: self)
        delegateBox = box
        terminal.processDelegate = box
        terminal.onClear = { [weak self] in self?.clearScrollback() }
    }

    var isLive: Bool { !isExited }
    var isExited: Bool { if case .exited = state { return true } else { return false } }

    func start() {
        let cmd = CommandBuilder.command(host: host, mode: mode, session: session, cwd: cwd, env: env,
                                         attachOnly: attachOnly)
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("COLORTERM=truecolor")
        let inherited = ProcessInfo.processInfo.environment
        if let path = inherited["PATH"] { env.append("PATH=\(path)") }
        if !env.contains(where: { $0.hasPrefix("LANG=") }) { env.append("LANG=\(inherited["LANG"] ?? "en_US.UTF-8")") }
        state = .connecting
        terminal.holdInput()
        terminal.setProcessOutputHandler { [weak self] in
            Task { @MainActor in self?.didReceiveOutput() }
        }
        terminal.startProcess(executable: cmd.executable, args: cmd.args, environment: env,
                              currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Respawns the same command (same cwd and env), which reattaches the same tmux session.
    func reconnect() {
        if terminal.process?.running == true { terminal.terminate() }
        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        start()
    }

    /// Ends the client (ssh or tmux client). The tmux session keeps running.
    func close() {
        terminal.processDelegate = nil
        if terminal.process?.running == true { terminal.terminate() }
    }

    /// Kills the tmux session on its host, then closes the client.
    func killSession() async {
        _ = await Runner.run(CommandBuilder.killCommand(host: host, session: session))
        close()
    }

    /// Cmd+K, like Terminal.app: drops the scrollback and clears the screen. Ctrl+L makes
    /// the app inside (shell or Claude Code) clear and redraw, so tmux's screen stays in
    /// sync, then tmux's own history goes too once the app has cleared.
    func clearScrollback() {
        terminal.leaveTmuxScrollback()
        terminal.clearScrollback()
        terminal.write([0x0c])
        let cmd = CommandBuilder.oneShot(host: host, script: "tmux clear-history -t '=\(session):' 2>/dev/null")
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            _ = await Runner.run(cmd)
        }
    }

    func send(text: String) { terminal.write(ArraySlice(Array(text.utf8))) }

    /// Sends text like a paste: bracketed when the app inside asked for it, so a
    /// multi line relay does not submit early. No Enter is appended.
    func sendPaste(_ text: String) {
        if terminal.terminalInputStateSnapshot()?.bracketedPasteMode == true {
            send(text: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            send(text: text.replacingOccurrences(of: "\n", with: "\r"))
        }
    }

    /// Plain text of the visible screen, for tests and the automation hook.
    func screenText() -> String {
        guard let snap = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1)) else { return "" }
        return snap.rows.map { $0.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    var selectedText: String? {
        guard let s = terminal.getSelection(), !s.isEmpty else { return nil }
        return s
    }

    fileprivate func didReceiveOutput() {
        lastOutput = Date()
        if state == .connecting {
            state = .live
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.terminal.releaseInput() }
        }
    }
    fileprivate func didExit(_ code: Int32?) {
        terminal.releaseInput()
        state = .exited(code)
    }
    fileprivate func didSetTitle(_ t: String) { title = t }

    final class Delegate: LocalProcessTerminalViewDelegate {
        weak var owner: PaneSession?
        init(owner: PaneSession) { self.owner = owner }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor in self.owner?.didSetTitle(title) }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor in self.owner?.didExit(exitCode) }
        }
        func processFailedToStart(source: TerminalView, error: LocalProcessError) {
            Task { @MainActor in self.owner?.didExit(nil) }
        }
        func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {}
    }
}
