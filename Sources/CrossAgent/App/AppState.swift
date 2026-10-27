import AppKit
import Combine
import SwiftUI

/// Everything the window shows: panes, focus, broadcast, layout persistence.
@MainActor
final class AppState: ObservableObject {
    let hosts: [Host]
    /// Watches ca-* tmux sessions on every host. Feeds the station and free name picking.
    var monitor: TmuxMonitor?
    /// Mutagen ca-* sync sessions for the top bar. Started by AppDelegate.
    let sync = SyncMonitor()

    @Published private(set) var panes: [PaneSession] = []
    @Published var focusedID: UUID?
    @Published var maximizedID: UUID?
    @Published private(set) var broadcast = false
    @Published var showStation = false
    @Published var lastHostID: String
    /// Short lived message shown at the bottom of the window.
    @Published var toast: String?
    /// New pane popover in the top bar.
    @Published var showNewPane = false
    /// Relay picker overlay, and the highlighted row in it.
    @Published var showRelayPicker = false
    @Published var relayPickIndex = 0
    /// Bumped whenever any pane changes state, so host chips can recount live panes.
    @Published private(set) var paneStateVersion = 0
    private var stateWatchers: [UUID: AnyCancellable] = [:]

    private static let layoutKey = "layout.v1"
    private static let lastHostKey = "lastHostID"

    init(hosts: [Host] = HostStore.load()) {
        self.hosts = hosts
        lastHostID = UserDefaults.standard.string(forKey: Self.lastHostKey) ?? hosts.first?.id ?? "mac"
    }

    func host(_ id: String) -> Host? { hosts.first { $0.id == id } }

    var focused: PaneSession? { panes.first { $0.id == focusedID } }

    func paneCount(host: Host) -> Int { panes.filter { $0.host.id == host.id }.count }

    func liveCount(host: Host) -> Int { panes.filter { $0.host.id == host.id && $0.isLive }.count }

    private func track(_ pane: PaneSession) {
        stateWatchers[pane.id] = pane.$state.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.paneStateVersion += 1 }
        }
    }

    // MARK: Panes

    /// Opens a pane. A nil or empty session name picks the next free `ca-<host>-<n>`.
    @discardableResult
    func newPane(hostID: String? = nil, mode: PaneMode = .claude, session: String? = nil, taken: Set<String> = []) -> PaneSession? {
        guard let host = host(hostID ?? lastHostID) ?? hosts.first else { return nil }
        let name: String
        if let s = session?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            guard SessionName.isValid(s) else {
                flash("Session names are letters, digits, - and _ (max 40)")
                return nil
            }
            name = s
        } else {
            // Before the monitor has heard from this host we don't know its sessions,
            // and `tmux new -A` would silently attach to an existing ca-<host>-1. Ask first.
            if let monitor, !monitor.hasPolled(host: host) {
                Task { [weak self] in
                    let r = await Runner.run(CommandBuilder.oneShot(host: host, script: "tmux ls -F '#{session_name}' 2>/dev/null || true"))
                    let names = Set(r.stdout.split(separator: "\n").map(String.init))
                    self?.newPane(hostID: host.id, mode: mode, session: self?.nextSessionName(host: host, taken: taken.union(names)), taken: taken)
                }
                return nil
            }
            name = nextSessionName(host: host, taken: taken)
        }
        if let existing = panes.first(where: { $0.host.id == host.id && $0.session == name }) {
            focus(existing.id)
            return existing
        }
        let pane = PaneSession(host: host, mode: mode, session: name)
        wire(pane)
        track(pane)
        panes.append(pane)
        lastHostID = host.id
        UserDefaults.standard.set(host.id, forKey: Self.lastHostKey)
        pane.start()
        focus(pane.id)
        saveLayout()
        monitor?.refreshNow()
        return pane
    }

    func nextSessionName(host: Host, taken: Set<String> = []) -> String {
        let used = Set(panes.filter { $0.host.id == host.id }.map(\.session))
            .union(taken)
            .union(monitor?.sessionNames(host: host) ?? [])
        var n = 1
        while used.contains("ca-\(host.id)-\(n)") { n += 1 }
        return "ca-\(host.id)-\(n)"
    }

    /// Closes the pane's client. Its tmux session keeps running.
    func close(_ id: UUID? = nil) {
        guard let id = id ?? focusedID, let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        let pane = panes.remove(at: idx)
        pane.close()
        stateWatchers[id] = nil
        if maximizedID == id { maximizedID = nil }
        if focusedID == id {
            let next = panes.isEmpty ? nil : panes[min(idx, panes.count - 1)].id
            focusedID = nil
            if let next { focus(next) }
        }
        saveLayout()
    }

    /// Kills the tmux session on its host, then removes the pane.
    func kill(_ id: UUID) {
        guard let pane = panes.first(where: { $0.id == id }) else { return }
        Task {
            await pane.killSession()
            close(id)
        }
    }

    func reconnect(_ id: UUID? = nil) {
        guard let pane = panes.first(where: { $0.id == (id ?? focusedID) }) else { return }
        pane.reconnect()
        focus(pane.id)
    }

    // MARK: Window

    /// The main window, handed over by ContentView once it is on screen.
    private(set) weak var window: NSWindow?
    private var responderObservation: NSKeyValueObservation?

    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.backgroundColor = Theme.window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        sync.updateLoop()
        // Clicks into a terminal make it first responder; follow that to move pane focus.
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] win, _ in
            DispatchQueue.main.async { self?.noteFirstResponder(win.firstResponder) }
        }
    }

    // MARK: Focus

    func focus(_ id: UUID) {
        guard let pane = panes.first(where: { $0.id == id }) else { return }
        if focusedID != id { focusedID = id }
        if let max = maximizedID, max != id { maximizedID = id }
        // Defer so the view is in the window after a relayout.
        DispatchQueue.main.async {
            pane.terminal.window?.makeFirstResponder(pane.terminal)
        }
    }

    func focus(index: Int) {
        guard panes.indices.contains(index) else { return }
        focus(panes[index].id)
    }

    func moveFocus(_ delta: Int) {
        guard !panes.isEmpty else { return }
        let cur = panes.firstIndex { $0.id == focusedID } ?? 0
        focus(index: (cur + delta + panes.count) % panes.count)
    }

    /// Called when a terminal becomes first responder by a click.
    func noteFirstResponder(_ view: NSResponder?) {
        guard let pane = panes.first(where: { $0.terminal === view }), focusedID != pane.id else { return }
        focusedID = pane.id
        if maximizedID != nil { maximizedID = pane.id }
    }

    func toggleMaximize(_ id: UUID? = nil) {
        guard let id = id ?? focusedID else { return }
        maximizedID = (maximizedID == id) ? nil : id
        focus(id)
    }

    // MARK: Broadcast

    func toggleBroadcast() { setBroadcast(!broadcast) }

    func setBroadcast(_ on: Bool) {
        broadcast = on
        for pane in panes { wire(pane) }
        flash(on ? "Broadcast on, typing goes to every live pane" : "Broadcast off")
    }

    private func wire(_ pane: PaneSession) {
        if broadcast {
            pane.terminal.inputInterceptor = { [weak self] data in
                MainActor.assumeIsolated { self?.broadcastInput(data) }
            }
        } else {
            pane.terminal.inputInterceptor = nil
        }
    }

    private func broadcastInput(_ data: ArraySlice<UInt8>) {
        for pane in panes where pane.isLive { pane.terminal.write(data) }
    }

    // MARK: Relay

    /// Panes that can receive a relay from the focused pane.
    var relayTargets: [PaneSession] { panes.filter { $0.id != focusedID && $0.isLive } }

    /// Sends the focused pane's selection to `target`, without a trailing Enter.
    func relay(to target: UUID, from source: UUID? = nil) {
        guard let src = panes.first(where: { $0.id == (source ?? focusedID) }),
              let dst = panes.first(where: { $0.id == target }) else { return }
        guard let text = src.selectedText else {
            flash("Select some text first")
            return
        }
        dst.sendPaste(text)
        flash("Relayed \(text.count) chars to \(dst.host.name) \(dst.session)")
    }

    func openRelayPicker() {
        guard focused != nil else { return }
        guard !relayTargets.isEmpty else {
            flash("No other live panes to relay to")
            return
        }
        relayPickIndex = 0
        showRelayPicker = true
    }

    func closeRelayPicker() {
        showRelayPicker = false
        if let id = focusedID { focus(id) }
    }

    /// Relays to the picker's row `index` and closes the picker.
    func pickRelay(_ index: Int) {
        let targets = relayTargets
        guard targets.indices.contains(index) else { return }
        showRelayPicker = false
        relay(to: targets[index].id)
        if let id = focusedID { focus(id) }
    }

    // MARK: Toast

    private var toastTask: Task<Void, Never>?

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Layout persistence

    struct SavedPane: Codable, Equatable {
        var hostId: String
        var mode: PaneMode
        var session: String
    }

    func saveLayout() {
        let saved = panes.map { SavedPane(hostId: $0.host.id, mode: $0.mode, session: $0.session) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.layoutKey)
        }
    }

    /// Reopens the saved panes, which reattaches their tmux sessions.
    func restoreLayout() {
        guard panes.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.layoutKey),
              let saved = try? JSONDecoder().decode([SavedPane].self, from: data) else { return }
        for s in saved where host(s.hostId) != nil && SessionName.isValid(s.session) {
            let pane = PaneSession(host: host(s.hostId)!, mode: s.mode, session: s.session)
            wire(pane)
            track(pane)
            panes.append(pane)
            pane.start()
        }
        if let first = panes.first { focus(first.id) }
    }

    /// Opens an ssh master per remote host in the background so the first pane opens fast.
    func warmUpConnections() {
        for host in hosts where !host.isLocal {
            Task.detached { _ = Runner.runSync(CommandBuilder.oneShot(host: host, script: "true"), timeout: 30) }
        }
    }
}
