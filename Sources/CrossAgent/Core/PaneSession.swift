import AppKit
import SwiftTerm

/// A LocalProcessTerminalView that can hand user input to someone else (broadcast).
final class PaneTerminalView: LocalProcessTerminalView {
    /// When set, user keystrokes go here instead of straight to the process.
    var inputInterceptor: ((ArraySlice<UInt8>) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let inputInterceptor { inputInterceptor(data) } else { super.send(source: source, data: data) }
    }

    /// Writes bytes straight to the process, skipping the interceptor.
    func write(_ data: ArraySlice<UInt8>) {
        guard process?.running == true else { return }
        process.send(data: data)
    }
}

/// One pane: a host, a mode, a tmux session, and the live terminal view.
@MainActor
final class PaneSession: ObservableObject, Identifiable {
    enum State: Equatable { case connecting, live, exited(Int32?) }

    let id = UUID()
    let host: Host
    let mode: PaneMode
    let session: String
    let terminal: PaneTerminalView
    let startedAt = Date()

    @Published private(set) var state: State = .connecting
    @Published private(set) var title: String = ""
    /// Last time the process printed anything. Not published, read on demand.
    private(set) var lastOutput = Date()

    private var delegateBox: Delegate?

    init(host: Host, mode: PaneMode, session: String) {
        self.host = host
        self.mode = mode
        self.session = session
        terminal = PaneTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        Theme.apply(to: terminal)
        let box = Delegate(owner: self)
        delegateBox = box
        terminal.processDelegate = box
    }

    var isLive: Bool { !isExited }
    var isExited: Bool { if case .exited = state { return true } else { return false } }

    func start() {
        let cmd = CommandBuilder.command(host: host, mode: mode, session: session)
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("COLORTERM=truecolor")
        let inherited = ProcessInfo.processInfo.environment
        if let path = inherited["PATH"] { env.append("PATH=\(path)") }
        if !env.contains(where: { $0.hasPrefix("LANG=") }) { env.append("LANG=\(inherited["LANG"] ?? "en_US.UTF-8")") }
        state = .connecting
        terminal.setProcessOutputHandler { [weak self] in
            Task { @MainActor in self?.didReceiveOutput() }
        }
        terminal.startProcess(executable: cmd.executable, args: cmd.args, environment: env,
                              currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Respawns the same command, which reattaches the same tmux session.
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

    func send(text: String) { terminal.write(ArraySlice(Array(text.utf8))) }

    var selectedText: String? {
        guard let s = terminal.getSelection(), !s.isEmpty else { return nil }
        return s
    }

    fileprivate func didReceiveOutput() {
        lastOutput = Date()
        if state == .connecting { state = .live }
    }
    fileprivate func didExit(_ code: Int32?) { state = .exited(code) }
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
