import AppKit

/// A new pane waiting on a host that does not have the project folder yet.
struct FolderPrompt: Equatable {
    enum Phase: Equatable { case missing, syncing, failed(String) }

    var host: Host
    var mode: PaneMode
    var session: String?
    var projectPath: String
    var phase: Phase = .missing
}

extension AppState {
    // MARK: Projects

    /// The Welcome tab is up: no project open.
    var showsWelcome: Bool { project == nil && mode == .welcome }

    /// Opens a project and resets the window chrome. The old project stays open behind it.
    func switchProject(_ url: URL) {
        resetChrome()
        openProject(url)
    }

    func leaveProject() {
        resetChrome()
        closeProject()
        objectWillChange.send()
    }

    private func resetChrome() {
        showRelayPicker = false
        showNewPane = false
        folderPrompt = nil
        maximizedID = nil
    }

    /// Folder picker as a sheet on the window.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Pick a project folder"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] r in
            guard r == .OK, let url = panel?.url else { return }
            self?.switchProject(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    func removeRecent(path: String) {
        store.removeRecent(path: path)
        objectWillChange.send()
    }

    func clearRecents() {
        for r in store.recents() { store.removeRecent(path: r.path) }
        objectWillChange.send()
    }

    /// True when Mutagen is syncing the open project.
    var projectSyncActive: Bool {
        guard let project else { return false }
        return sync.sessions.contains { $0.name == project.syncSessionName }
    }

    // MARK: Modes

    /// Shows the tab for a mode (automation's "mode").
    func toggleModeOn(_ m: AppMode) {
        if mode != m { toggleMode(m) }
    }

    /// Pressing the shortcut of the tab that's up goes back to the tab before it.
    func toggleMode(_ m: AppMode) {
        let kind: TabKind
        switch m {
        case .station: kind = .station
        case .orchestrator: kind = .orchestrator
        case .activity: kind = .activity
        case .panes: kind = .panes
        default: return
        }
        if mode == m { selectPrevious() } else { open(kind) }
    }

    // MARK: New pane with a folder check

    func openNewPanePopover() {
        if project == nil { flash("Open a project first") } else { showNewPane = true }
    }

    /// Like `newPane`, but first makes sure the project folder exists on an ssh host.
    /// If it does not, `folderPrompt` asks whether to start sync or use the home folder.
    func requestPane(hostID: String, mode: PaneMode, session: String?) {
        guard let project, let host = host(hostID), !host.isLocal else {
            newPane(hostID: hostID, mode: mode, session: session)
            return
        }
        let key = project.path + "|" + host.id
        let name = session?.trimmingCharacters(in: .whitespaces) ?? ""
        // Reattaching a running session does not care about the folder.
        let reattach = !name.isEmpty && monitor?.sessionNames(host: host).contains(name) == true
        if foldersFound.contains(key) || reattach {
            newPane(hostID: hostID, mode: mode, session: session)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let found = await self.remoteFolderExists(host: host)
            guard self.project?.path == project.path else { return }
            if found {
                self.foldersFound.insert(key)
                self.newPane(hostID: hostID, mode: mode, session: session)
            } else {
                self.folderPrompt = FolderPrompt(host: host, mode: mode, session: session, projectPath: project.path)
            }
        }
    }

    func promptStartSync() {
        guard var prompt = folderPrompt, prompt.phase != .syncing else { return }
        prompt.phase = .syncing
        folderPrompt = prompt
        Task { [weak self] in
            guard let self else { return }
            let r = await self.startSync()
            guard self.folderPrompt?.projectPath == prompt.projectPath, self.project?.path == prompt.projectPath else { return }
            if r.ok {
                self.foldersFound.insert(prompt.projectPath + "|" + prompt.host.id)
                self.folderPrompt = nil
                self.newPane(hostID: prompt.host.id, mode: prompt.mode, session: prompt.session)
            } else {
                prompt.phase = .failed(r.output.isEmpty ? "ca sync start failed" : r.output)
                self.folderPrompt = prompt
            }
        }
    }

    func promptOpenInHome() {
        guard let prompt = folderPrompt, prompt.phase != .syncing else { return }
        folderPrompt = nil
        newPane(hostID: prompt.host.id, mode: prompt.mode, session: prompt.session, cwdOverride: "$HOME")
    }

    func cancelFolderPrompt() {
        guard folderPrompt != nil else { return }
        folderPrompt = nil
        if let id = focusedID { focus(id) }
    }
}

/// `/Users/me/x` as `~/x`.
func tildePath(_ path: String, home: String = NSHomeDirectory()) -> String {
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
