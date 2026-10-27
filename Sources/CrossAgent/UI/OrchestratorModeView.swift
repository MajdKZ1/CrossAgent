import SwiftUI

/// Orchestrator tab: a start card until the orchestrator runs, then the canvas with the
/// relay card on top. Clicking a node opens its agent tab.
struct OrchestratorModeView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if let o = app.orch, let pane = app.orchestratorPane {
                ShownGraph(orch: o, pane: pane)
            } else {
                StartCard(orch: app.orch)
            }
        }
        .background(Palette.window)
        .clipShape(RoundedRectangle(cornerRadius: Palette.radius, style: .continuous))
    }
}

// MARK: - Start card

private struct StartCard: View {
    @EnvironmentObject private var app: AppState
    var orch: ProjectOrchestrator?
    @State private var hostID = ""

    var body: some View {
        let host = app.host(hostID) ?? app.hosts.first
        let tint = host.map(Palette.accent) ?? Palette.text
        VStack(spacing: 14) {
            VStack(spacing: 5) {
                Text("Orchestrator")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text("One Claude Code session in tmux that runs the show. Its agents show up here as they work.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                ForEach(app.hosts) { h in
                    Button { hostID = h.id } label: {
                        HStack(spacing: 6) { Dot(color: Palette.accent(h), size: 6); Text(h.name) }
                    }
                    .buttonStyle(ChromeButtonStyle(active: h.id == host?.id, tint: Palette.accent(h)))
                }
            }
            Button {
                if let host { app.launchOrchestrator(hostID: host.id) }
            } label: {
                HStack(spacing: 6) {
                    if orch?.busy == true { ProgressView().controlSize(.mini) }
                    Text(orch?.busy == true ? "Adding hooks" : "Start orchestrator")
                }
            }
            .buttonStyle(ChromeButtonStyle(active: true, tint: tint))
            .disabled(orch?.busy == true)
            Text("CrossAgent adds hooks to this project's .claude/settings.local.json. Turn them off from the Orchestrator menu.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.075)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if hostID.isEmpty { hostID = app.orchestratorInfo?.hostId ?? app.hosts.first(where: \.isLocal)?.id ?? app.lastHostID } }
    }
}

// MARK: - Canvas

/// Follows `demoGraph`, so the demo swaps in and out of the canvas.
private struct ShownGraph: View {
    @ObservedObject var orch: ProjectOrchestrator
    var pane: PaneSession

    var body: some View {
        OrchestratorCanvas(orch: orch, graph: orch.shown, pane: pane)
    }
}

private struct OrchestratorCanvas: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var orch: ProjectOrchestrator
    @ObservedObject var graph: AgentGraph
    var pane: PaneSession

    var body: some View {
        // The demo drags into its own map, so none of it is saved.
        let positions = orch.demoGraph != nil
            ? Binding(get: { orch.demoPositions }, set: { orch.demoPositions = $0 })
            : Binding(get: { app.nodePositions }, set: {
                app.nodePositions = $0
                app.scheduleOrchestratorSave()
            })
        ZStack {
            OrchestratorView(graph: graph, hosts: app.hosts, positions: positions, actions: OrchestratorActions(
                expand: { app.expandNode($0) },
                relay: { app.openNodeRelay(from: $0, to: $1) },
                clearFinished: { app.clearFinishedAgents() },
                answer: { app.answerNode($0) }),
                showsClearFinished: orch.relay == nil)
            if let relay = orch.relay, let node = graph.nodes[relay.to] {
                Backdrop { orch.relay = nil }
                RelayCard(orch: orch, relay: relay, target: node)
                    .id(relay.from + ">" + relay.to)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: orch.relay)
    }
}

private struct Backdrop: View {
    var onTap: () -> Void

    var body: some View {
        Color.black.opacity(0.45)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .transition(.opacity)
    }
}

/// Card chrome for the relay card.
private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.075)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }
}

// MARK: - Relay card

private struct RelayCard: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var orch: ProjectOrchestrator
    @State var relay: NodeRelay
    var target: AgentNode
    @FocusState private var focused: Bool

    var body: some View {
        let tint = app.host(target.hostId).map(Palette.accent) ?? Palette.text
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Dot(color: tint, size: 6)
                Text("Send to \(target.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
            }
            Text(target.kind == .subagent ? "Goes through the orchestrator as @\(target.name)" : "Pasted into its terminal, no Enter")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
            TextField("What to send", text: $relay.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.text)
                .lineLimit(3...10)
                .focused($focused)
                .onSubmit(send)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.border))
            HStack(spacing: 6) {
                Text("↩ send   esc cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.faint)
                Spacer()
                Button("Cancel") { orch.relay = nil }
                    .buttonStyle(ChromeButtonStyle())
                Button("Send", action: send)
                    .buttonStyle(ChromeButtonStyle(active: true, tint: tint))
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 380)
        .modifier(CardChrome())
        .onAppear { focused = true }
    }

    private func send() { app.sendNodeRelay(relay) }
}
