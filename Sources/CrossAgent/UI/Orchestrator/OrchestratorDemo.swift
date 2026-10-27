import SwiftUI

/// Dev only: a window with the orchestrator canvas fed by scripted events,
/// opened with CROSSAGENT_ORCH_DEMO=1.
enum OrchestratorDemo {
    @MainActor static func openIfRequested() {}
}
