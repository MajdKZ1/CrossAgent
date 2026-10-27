import Foundation

extension AppState {
    /// Jumps from a station tile into the session: a pane in the grid already showing it
    /// comes up at full size, anything else opens as an agent tab.
    func openFromStation(_ info: TmuxSessionInfo) {
        if let pane = panes.first(where: { $0.host.id == info.hostId && $0.session == info.name }) {
            // The tmux session is alive, so an exited client just needs to reattach.
            if pane.isExited { pane.reconnect() }
            showFromStation(pane)
            return
        }
        openAgent(.session(host: info.hostId, name: info.name))
    }

    /// Opens a window pane whose process exited (its tmux session is gone too).
    func openFromStation(pane: PaneSession) {
        guard panes.contains(where: { $0.id == pane.id }) else { return }
        showFromStation(pane)
    }

    private func showFromStation(_ pane: PaneSession) {
        maximizedID = pane.id
        open(.panes)
        focus(pane.id)
        // The grid becomes visible on the next layout pass; focus again once it is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focus(pane.id) }
    }
}
