import SwiftUI

/// An agent's tab: the orchestrator's or a worker's live terminal (any tmux session,
/// really), or for a built-in subagent what it was asked and did, with a box that
/// talks to it through the orchestrator. Kept alive while hidden, like the pane grid.
struct AgentTabView: View {
    @EnvironmentObject private var app: AppState
    var tab: Tab
    var selected: Bool

    var body: some View {
        if let o = app.orch {
            AgentTabGraph(orch: o, tab: tab, selected: selected)
        } else {
            AgentTabBody(tab: tab, node: nil, selected: selected)
        }
    }
}

/// Follows `demoGraph`, like the canvas.
private struct AgentTabGraph: View {
    @ObservedObject var orch: ProjectOrchestrator
    var tab: Tab
    var selected: Bool

    var body: some View {
        AgentTabNode(graph: orch.shown, orch: orch, tab: tab, selected: selected)
    }
}

private struct AgentTabNode: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var graph: AgentGraph
    @ObservedObject var orch: ProjectOrchestrator
    var tab: Tab
    var selected: Bool

    var body: some View {
        AgentTabBody(tab: tab, node: node, answering: orch.answering, selected: selected)
    }

    private var node: AgentNode? {
        switch tab.kind {
        case .agent(.node(let id)): return graph.nodes[id]
        case .agent(.session(let h, let name)):
            return graph.nodes.values.first { $0.hostId == h && $0.tmuxSession == name }
        default: return nil
        }
    }
}

private struct AgentTabBody: View {
    @EnvironmentObject private var app: AppState
    var tab: Tab
    var node: AgentNode?
    var answering: String?
    var selected: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Palette.radius, style: .continuous) }

    var body: some View {
        let hostID = node?.hostId ?? { if case .agent(let r) = tab.kind { return app.hostID(of: r) } else { return nil } }()
        let host = hostID.flatMap(app.host)
        VStack(spacing: 0) {
            header(host)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            content
        }
        .background(shape.fill(Palette.pane))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.border, lineWidth: 1).allowsHitTesting(false))
    }

    private func header(_ host: Host?) -> some View {
        HStack(spacing: 8) {
            Dot(color: host.map(Palette.accent) ?? Palette.faint, size: 7)
            Text(app.title(of: tab))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Text(caption(host))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let node { StateLabel(state: node.state) }
        }
        .padding(.horizontal, 12)
        .frame(height: Palette.headerHeight + 2)
    }

    private func caption(_ host: Host?) -> String {
        let where_ = host?.name ?? "?"
        switch tab.kind {
        case .agent(.node(let id)) where id == AgentGraph.orchestratorID:
            if let a = answering { return "Orchestrator on \(where_), answer for \(a) here" }
            return "Orchestrator on \(where_)"
        case .agent(.session(_, let name)):
            if node?.kind == .worker { return "Worker on \(where_), \(name)" }
            return "\(where_), \(name)"
        default:
            if node?.kind == .subagent { return "Built-in subagent, messages go through the orchestrator" }
            return where_
        }
    }

    @ViewBuilder private var content: some View {
        switch tab.kind {
        case .agent(.node(let id)) where id == AgentGraph.orchestratorID:
            if let pane = app.orchestratorPane {
                LiveTerminal(pane: pane, ended: "The orchestrator disconnected", hidden: !selected)
            } else {
                Ended(text: "The orchestrator isn't running")
            }
        case .agent(.session):
            if let pane = app.agentPanes[tab.id] {
                LiveTerminal(pane: pane, ended: node?.kind == .worker ? "This worker's session has ended" : "This session has ended",
                             hidden: !selected)
            } else {
                Palette.pane
            }
        default:
            if let node, node.kind == .subagent {
                SubagentDetail(node: node, selected: selected)
            } else {
                Ended(text: node == nil ? "This agent is gone" : "This agent has no terminal")
            }
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
    /// Behind another tab: kept at its size, not drawn.
    var hidden = false

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
                TerminalHost(terminal: pane.terminal, hidden: hidden)
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
    var selected: Bool
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
        .onAppear { if selected { focused = true } }
        .onChange(of: selected) { _, on in if on { focused = true } }
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

