import SwiftUI

/// The CrossAgent mascot. Sits on the orchestrator node and reacts to the graph.
/// Placeholder until the real character lands.
struct MascotView: View {
    @ObservedObject var graph: AgentGraph

    var body: some View {
        Circle().fill(Palette.faint).frame(width: 24, height: 24)
    }
}

/// Dev only: a window with every mascot state, opened with CROSSAGENT_MASCOT_GALLERY=1.
enum MascotGallery {
    @MainActor static func openIfRequested() {}
}
