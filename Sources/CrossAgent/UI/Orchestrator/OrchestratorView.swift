import SwiftUI

/// What the canvas asks the app to do. Wired up by whoever hosts the canvas.
struct OrchestratorActions {
    var expand: (String) -> Void = { _ in }
    var relay: (_ from: String, _ to: String) -> Void = { _, _ in }
    var clearFinished: () -> Void = {}
    var answer: (String) -> Void = { _ in }
}

/// The orchestrator canvas: the orchestrator in the middle, its agents hanging off it
/// on cables. Drag empty space or scroll to pan, pinch or Cmd scroll to zoom, double
/// click to recenter. Drag a node to pin it; drag its edge handle (or Option drag it)
/// onto another node to relay.
struct OrchestratorView: View {
    @ObservedObject var graph: AgentGraph
    var hosts: [Host]
    /// Where the user dragged nodes, canvas coordinates with the orchestrator at (0,0).
    @Binding var positions: [String: CGPoint]
    var actions = OrchestratorActions()

    var body: some View {
        CanvasStageView(graph: graph, hosts: hosts, positions: $positions, actions: actions)
            .background(Palette.window)
            .clipped()
            .overlay(alignment: .bottomLeading) { clearButton }
    }

    @ViewBuilder private var clearButton: some View {
        if !graph.finished.isEmpty {
            Button {
                actions.clearFinished()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text("Clear finished")
                    Text("\(graph.finished.count)").foregroundStyle(Palette.muted)
                }
            }
            .buttonStyle(ChromeButtonStyle())
            .padding(12)
            .transition(.opacity)
        }
    }
}
