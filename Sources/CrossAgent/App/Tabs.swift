import Foundation

// Contract for the single window tab strip. The tabs work fills these in; other
// parts of the app (canvas, station, activity, mascot orbs) only call `openAgent`.

/// Something that can be opened as an agent chat tab.
enum AgentRef: Hashable, Codable {
    /// A node in the current project's AgentGraph (orchestrator, subagent or worker).
    case node(String)
    /// Any tmux session on a host, opened as its live terminal.
    case session(host: String, name: String)
}

/// One tab in the main window.
enum TabKind: Hashable, Codable {
    case welcome, panes, station, orchestrator, activity
    case agent(AgentRef)
}

extension AppState {
    /// Opens (or focuses, if already open) a tab of this kind in the current project.
    func open(_ kind: TabKind) {
        switch kind {
        case .panes: mode = .panes
        case .station: mode = .station
        case .orchestrator: mode = .orchestrator
        default: break
        }
    }

    /// Opens an agent's chat as a tab, or jumps to it if it's already open.
    func openAgent(_ ref: AgentRef) {
        open(.agent(ref))
    }
}
