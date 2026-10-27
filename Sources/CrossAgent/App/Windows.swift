import AppKit
import CryptoKit
import SwiftUI

/// One window per open project, like Xcode, each with its own AppState. A welcome
/// window shows only while no project is open. Owns what all windows share: the
/// hosts and the tmux monitor (sync, activity and the theme have their own `shared`).
@MainActor
final class ProjectWindows: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ProjectWindows()

    private struct Entry {
        let state: AppState
        let window: NSWindow
    }

    let hosts: [Host]
    let monitor: TmuxMonitor
    let store = ProjectStore()
    /// Front first: the key window, then the ones focused before it.
    private var entries: [Entry] = []
    /// The key window's state, or the last one that was key (Settings can be key).
    @Published private(set) var current: AppState?
    private var keyObserver: NSObjectProtocol?
    /// Set once quitting starts. Windows closing after that keep their place in the open list.
    private var quitting = false

    private static let defaultSize = NSSize(width: 1200, height: 760)
    private static let noActivate = ProcessInfo.processInfo.environment["CROSSAGENT_NO_ACTIVATE"] == "1"

    private init(hosts: [Host] = HostStore.load()) {
        self.hosts = hosts
        monitor = TmuxMonitor(hosts: hosts)
        super.init()
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                             queue: .main) { [weak self] note in
            let win = note.object as? NSWindow
            MainActor.assumeIsolated { self?.bringToFront(win) }
        }
    }

    // MARK: Lookup

    var states: [AppState] { entries.map(\.state) }

    /// Open project paths, in the order the Window menu lists them.
    var openPaths: [String] { entries.reversed().compactMap(\.state.project?.path) }

    func state(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        // A merged window tab is its own NSWindow, so this holds for tabs too.
        return entries.first { $0.window === window }?.state
    }

    func state(path: String) -> AppState? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return entries.first { $0.state.project?.path == path }?.state
    }

    func window(of state: AppState) -> NSWindow? { entries.first { $0.state === state }?.window }

    // MARK: Launch and quit

    /// Every project that was open comes back in its own window, else the welcome window.
    func restore() {
        monitor.start()
        SyncMonitor.shared.start { [weak self] in self?.entries.map(\.window) ?? [] }
        warmUpConnections()
        for path in store.pathsToRestore() { open(URL(fileURLWithPath: path, isDirectory: true)) }
        if entries.isEmpty { showWelcome() }
    }

    /// Quit starts: the open list is saved as it is now. With no window left (the last
    /// one was just closed) it already holds that one's project.
    func prepareToQuit() {
        if !entries.isEmpty { saveOpenList() }
        quitting = true
    }

    /// Saves every window's state and closes all terminal clients. tmux sessions keep running.
    func saveAndCloseAll() {
        prepareToQuit()
        for e in entries { e.state.closeProject() }
    }

    /// Opens an ssh master per remote host in the background so the first pane opens fast.
    private func warmUpConnections() {
        for host in hosts where !host.isLocal {
            Task.detached { _ = Runner.runSync(CommandBuilder.oneShot(host: host, script: "true"), timeout: 30) }
        }
    }

    // MARK: Open and close

    /// Opens the project in its own window, or brings its window forward if it is open
    /// already. A welcome window is replaced. `from` gets the error toast.
    func open(_ url: URL, from: AppState? = nil) {
        let path = url.standardizedFileURL.path
        guard ProjectStore.folderExists(path) else {
            (from ?? current)?.flash("That folder is gone")
            store.removeRecent(path: path)
            recentsChanged()
            return
        }
        if let e = entries.first(where: { $0.state.project?.path == path }) {
            show(e.window)
            return
        }
        let welcome = entries.first { $0.state.project == nil }
        let state = AppState(hosts: hosts)
        state.monitor = monitor
        let win = makeWindow(for: state, title: Project(url: url).name)
        let name = Self.frameName(path: path)
        if !win.setFrameUsingName(name) { place(win, like: welcome?.window) }
        win.setFrameAutosaveName(name)
        entries.insert(Entry(state: state, window: win), at: 0)
        current = state
        state.openProject(url)
        show(win)
        if let welcome { welcome.window.close() }
        saveOpenList()
    }

    /// The welcome window, made if there is none.
    func showWelcome() {
        if let e = entries.first(where: { $0.state.project == nil }) {
            show(e.window)
            return
        }
        let state = AppState(hosts: hosts)
        state.monitor = monitor
        let win = makeWindow(for: state, title: "CrossAgent")
        if !win.setFrameUsingName(Self.welcomeFrameName) { place(win, like: nil) }
        win.setFrameAutosaveName(Self.welcomeFrameName)
        entries.insert(Entry(state: state, window: win), at: 0)
        current = state
        show(win)
    }

    /// File > Close Project: closes the window. The last one is replaced by the
    /// welcome window, so the app stays up. Nothing is killed.
    func closeProject(_ state: AppState) {
        guard let e = entries.first(where: { $0.state === state }) else { return }
        if let path = state.project?.path {
            store.openProjectPaths = openPaths.filter { $0 != path }
        }
        if !entries.contains(where: { $0.state !== state }) { showWelcome() }
        e.window.close()
    }

    /// Folder picker for when no window is up to hang the sheet on.
    func presentOpenPanel() {
        if let current {
            current.presentOpenPanel()
            return
        }
        let panel = AppState.projectPanel()
        panel.begin { [weak self, weak panel] r in
            guard r == .OK, let url = panel?.url else { return }
            MainActor.assumeIsolated { self?.open(url) }
        }
    }

    /// Recents changed somewhere: menus that list them refresh.
    func recentsChanged() { objectWillChange.send() }

    // MARK: NSWindowDelegate

    /// Closing a window closes its project: state saved, terminal clients closed.
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow,
              let i = entries.firstIndex(where: { $0.window === win }) else { return }
        let e = entries.remove(at: i)
        // The last window going quits the app, and its project should come back next launch.
        if !quitting, e.state.project != nil, entries.contains(where: { $0.state.project != nil }) { saveOpenList() }
        e.state.closeProject()
        e.state.monitor = nil
        win.saveFrame(usingName: win.frameAutosaveName)
        // Frees the name in case the project opens again while this window still lives.
        win.setFrameAutosaveName("")
        win.delegate = nil
        if current === e.state { current = entries.first?.state }
        // Tears the SwiftUI views down now, so their onDisappear (fast polls, samplers) runs.
        DispatchQueue.main.async {
            win.contentView = nil
            SyncMonitor.shared.updateLoop()
        }
    }

    // MARK: Helpers

    private func makeWindow(for state: AppState, title: String) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        // We restore projects ourselves.
        win.isRestorable = false
        // Hidden, but the Window menu and merged window tabs show it.
        win.title = title
        win.tabbingMode = .automatic
        win.tabbingIdentifier = "CrossAgent.project"
        win.contentMinSize = NSSize(width: 640, height: 400)
        win.delegate = self
        let view = NSHostingView(rootView: ContentView().environmentObject(state).themed())
        // The window sets the size; the views only say how small it can go.
        view.sizingOptions = [.minSize]
        win.contentView = view
        state.attach(window: win)
        return win
    }

    /// A window with no saved frame takes the welcome window's place, else cascades
    /// from the front window, else sits centered.
    private func place(_ win: NSWindow, like other: NSWindow?) {
        if let other {
            win.setFrame(other.frame, display: false)
        } else if let front = entries.first?.window {
            win.setFrame(front.frame, display: false)
            let top = NSPoint(x: front.frame.minX, y: front.frame.maxY)
            win.setFrameTopLeftPoint(win.cascadeTopLeft(from: top))
        } else {
            win.center()
        }
    }

    /// Without CROSSAGENT_NO_ACTIVATE the window comes forward and takes the keyboard.
    private func show(_ win: NSWindow) {
        if Self.noActivate {
            if !win.isVisible { win.orderFront(nil) }
            bringToFront(win)
        } else {
            win.makeKeyAndOrderFront(nil)
        }
    }

    private func bringToFront(_ win: NSWindow?) {
        guard let i = entries.firstIndex(where: { $0.window === win }) else { return }
        let e = entries.remove(at: i)
        entries.insert(e, at: 0)
        if current !== e.state { current = e.state }
    }

    private func saveOpenList() { store.openProjectPaths = openPaths }

    // MARK: Frame names

    static let welcomeFrameName = "CrossAgent.welcome"

    /// Per project frame autosave name, from a hash so the path itself isn't in defaults.
    static func frameName(path: String) -> String {
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "CrossAgent.project.\(hash.prefix(12))"
    }
}

extension ProjectStore {
    static let openProjectsKey = "openProjects.v1"

    /// Paths of the projects open in windows. Nil until a build with windows saved it.
    var openProjectPaths: [String]? {
        get { defaults.stringArray(forKey: Self.openProjectsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.openProjectsKey) }
    }

    /// What reopens on launch: the open list, or the last project from before windows.
    /// Gone folders and duplicates are dropped.
    func pathsToRestore() -> [String] {
        var seen: Set<String> = []
        return (openProjectPaths ?? lastProjectPath.map { [$0] } ?? [])
            .filter { Self.folderExists($0) && seen.insert($0).inserted }
    }
}
