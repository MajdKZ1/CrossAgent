import Foundation

extension AppState {
    /// Jumps from a station tile into the session at full size: reuses the window pane for
    /// that host and session if there is one, otherwise opens a pane that attaches to it.
    func openFromStation(_ info: TmuxSessionInfo) {
        if let pane = panes.first(where: { $0.host.id == info.hostId && $0.session == info.name }) {
            // The tmux session is alive, so an exited client just needs to reattach.
            if pane.isExited { pane.reconnect() }
            showFromStation(pane)
            return
        }
        // `tmux new -A` attaches the existing session; the mode only matters if it is gone.
        if project == nil {
            // Attaching needs no project. Not saved anywhere, there is no project to save it in.
            guard let host = host(info.hostId), SessionName.isValid(info.name) else { return }
            let pane = PaneSession(host: host, mode: info.isClaude ? .claude : .shell, session: info.name)
            adopt(pane)
            showFromStation(pane)
            return
        }
        guard let pane = newPane(hostID: info.hostId, mode: info.isClaude ? .claude : .shell, session: info.name) else { return }
        showFromStation(pane)
    }

    /// Opens a window pane whose process exited (its tmux session is gone too).
    func openFromStation(pane: PaneSession) {
        guard panes.contains(where: { $0.id == pane.id }) else { return }
        showFromStation(pane)
    }

    private func showFromStation(_ pane: PaneSession) {
        maximizedID = pane.id
        focus(pane.id)
        showStation = false
        // The grid becomes visible on the next layout pass; focus again once it is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focus(pane.id) }
    }
}
