import SwiftUI

/// Orchestrator mode: a start card until the orchestrator runs, then the canvas with
/// the detail and relay cards on top.
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
        let positions = Binding(get: { app.nodePositions }, set: {
            app.nodePositions = $0
            app.scheduleOrchestratorSave()
        })
        ZStack {
            OrchestratorView(graph: graph, hosts: app.hosts, positions: positions, actions: OrchestratorActions(
                expand: { app.expandNode($0) },
                relay: { app.openNodeRelay(from: $0, to: $1) },
                clearFinished: { app.clearFinishedAgents() },
                answer: { app.answerNode($0) }),
                showsClearFinished: orch.detail == nil && orch.relay == nil)
            if let id = orch.detail, let node = graph.nodes[id] {
                Backdrop { app.closeDetail() }
                NodeDetailCard(orch: orch, node: node)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            if let relay = orch.relay, let node = graph.nodes[relay.to] {
                Backdrop { orch.relay = nil }
                RelayCard(orch: orch, relay: relay, target: node)
                    .id(relay.from + ">" + relay.to)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: orch.detail)
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

/// Small card chrome shared by the detail and relay cards.
private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.075)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }
}

// MARK: - Detail card

private struct NodeDetailCard: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var orch: ProjectOrchestrator
    var node: AgentNode

    var body: some View {
        let host = app.host(node.hostId)
        GeometryReader { geo in
            VStack(spacing: 0) {
                header(host)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                content(host)
            }
            .modifier(CardChrome())
            .frame(width: min(geo.size.width - 48, node.kind == .subagent ? 760 : 1100),
                   height: min(geo.size.height - 48, node.kind == .subagent ? 540 : 760))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ host: Host?) -> some View {
        let tint = host.map(Palette.accent) ?? Palette.text
        return HStack(spacing: 8) {
            Dot(color: tint, size: 7)
            Text(node.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Text(caption(host))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            StateLabel(state: node.state)
            Button { app.closeDetail() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .help("Close (esc)")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func caption(_ host: Host?) -> String {
        let where_ = host?.name ?? node.hostId
        switch node.kind {
        case .orchestrator:
            if let a = orch.answering { return "Orchestrator on \(where_), answer for \(a) here" }
            return "Orchestrator on \(where_)"
        case .worker: return "Runs in its own terminal on \(where_)"
        case .subagent: return "Built-in subagent, messages go through the orchestrator"
        }
    }

    @ViewBuilder private func content(_ host: Host?) -> some View {
        switch node.kind {
        case .orchestrator:
            if let pane = app.orchestratorPane {
                LiveTerminal(pane: pane, ended: "The orchestrator disconnected")
            } else {
                Ended(text: "The orchestrator isn't running")
            }
        case .worker:
            if let pane = orch.workerPanes[node.id] {
                LiveTerminal(pane: pane, ended: "This worker's session has ended")
            } else {
                Ended(text: "This worker's session has ended")
            }
        case .subagent:
            SubagentDetail(node: node)
        }
    }
}

private struct StateLabel: View {
    var state: AgentState

    var body: some View {
        let (text, color) = label
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var label: (String, Color) {
        switch state {
        case .thinking: return ("Thinking", Palette.primary)
        case .working: return ("Working", Palette.primary)
        case .needsInput: return ("Needs input", Palette.connecting)
        case .waiting: return ("Waiting", Palette.muted)
        case .idle: return ("Idle", Palette.muted)
        case .done: return ("Done", Palette.synced)
        case .error: return ("Error", Palette.danger)
        }
    }
}

/// A pane's terminal, live. Shows a quiet note once its process exits.
private struct LiveTerminal: View {
    @ObservedObject var pane: PaneSession
    var ended: String

    var body: some View {
        ZStack {
            Palette.pane
            if pane.isExited {
                VStack(spacing: 10) {
                    Text(ended)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    if !pane.attachOnly {
                        Button("Reconnect") { pane.reconnect() }
                            .buttonStyle(ChromeButtonStyle())
                    }
                }
            } else {
                TerminalHost(terminal: pane.terminal)
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct Ended: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.pane)
    }
}

/// A built-in subagent has no terminal: what it was asked, what it did lately, and a
/// box that talks to it through the orchestrator.
private struct SubagentDetail: View {
    @EnvironmentObject private var app: AppState
    var node: AgentNode
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(activityTitle) {
                        Text(activity)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.text.opacity(0.9))
                            .textSelection(.enabled)
                    }
                    if let p = node.prompt, !p.isEmpty {
                        section("Asked to") {
                            Text(p)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.text.opacity(0.85))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("Recent") {
                        if node.recent.isEmpty {
                            Text("Nothing yet").font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(node.recent.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                TextField("Message \(node.name)", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(ChromeButtonStyle(active: !text.isEmpty, tint: Palette.primary))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Palette.pane)
        .onAppear { focused = true }
    }

    private var activityTitle: String {
        switch node.state {
        case .done: return "Result"
        case .error: return "Error"
        default: return "Doing"
        }
    }

    private var activity: String {
        switch node.state {
        case .needsInput(let q): return q.isEmpty ? "Needs input, answer in the orchestrator" : q
        case .error(let e): return e.isEmpty ? "Failed" : e
        case .waiting(let names): return "Waiting on " + names.joined(separator: ", ")
        default: return node.activity.isEmpty ? "Starting" : node.activity
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        app.sendToNode(node.id, text: t)
        text = ""
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.faint)
            content()
        }
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
