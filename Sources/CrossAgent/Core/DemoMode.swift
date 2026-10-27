import Foundation

/// Debug only: CROSSAGENT_DEMO=1 runs the app on scripted demo data for recordings.
/// Nothing real is read or shown: no ssh, tmux on its own socket, fake sessions,
/// projects and machine stats, and a separate defaults domain. Release builds
/// always have it off.
enum DemoMode {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.environment["CROSSAGENT_DEMO"] == "1"
    #else
    static let isOn = false
    #endif

    /// tmux socket name for every demo session (`tmux -L ca-demo`).
    static let tmuxSocket = "ca-demo"
    /// Defaults domain used instead of the app's own while the demo runs.
    static let defaultsSuite = "dev.crossagent.demo"
}
