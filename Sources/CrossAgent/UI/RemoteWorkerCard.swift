import SwiftUI

/// A remote worker's card: its live tmux session on the other machine, the brief it
/// got and the report it wrote, with an approval card on top while it waits on you.
struct RemoteWorkerDetail: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var orch: ProjectOrchestrator
    var tab: Tab
    var node: AgentNode
    var selected: Bool

    var body: some View {
        let current = orch.remoteTabs[node.id] ?? .terminal
        VStack(spacing: 0) {
            if let ask = node.remote?.permission {
                ApprovalCard(node: node, ask: ask, send: orch.permissionSends[ask.id])
                    .padding(10)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            tabBar(current)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ZStack {
                terminal(shown: current == .terminal)
                if current != .terminal {
                    RemoteDocView(orch: orch, node: node, tab: current)
                }
            }
            if node.kind == .subagent {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                NodeMessageBox(node: node, selected: selected && current != .terminal)
            }
        }
        .background(Palette.pane)
        .onAppear { if current == .terminal { app.attachRemotePane(tabID: tab.id, node: node) } }
        .onChange(of: current) { _, t in if t == .terminal { app.attachRemotePane(tabID: tab.id, node: node) } }
    }

    private func tabBar(_ current: RemoteCardTab) -> some View {
        HStack(spacing: 4) {
            ForEach(RemoteCardTab.allCases, id: \.self) { t in
                Button(t.label) { app.setRemoteTab(node.id, t) }
                    .buttonStyle(ChromeButtonStyle(active: t == current, tint: Palette.text))
            }
            Spacer(minLength: 8)
            if let r = node.remote {
                Text(r.turn > 1 ? "\(r.role), turn \(r.turn)" : r.role)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private func terminal(shown: Bool) -> some View {
        if let pane = app.agentPanes[tab.id] {
            LiveTerminal(pane: pane, ended: "This worker's session has ended", hidden: !selected || !shown)
        } else {
            Palette.pane
        }
    }
}

// MARK: - Brief and result

/// brief.md or result.md from the worker's host. Read when the tab shows, again when
/// the path, the turn or running changes. Never polled.
private struct RemoteDocView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var orch: ProjectOrchestrator
    var node: AgentNode
    var tab: RemoteCardTab

    var body: some View {
        let doc = orch.remoteDocs[RemoteDoc.slot(node.id, tab)]
        Group {
            if let text = doc?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    MarkdownText(text: text)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let e = doc?.error {
                note(e, color: Palette.danger.opacity(0.9))
            } else if doc == nil || doc?.loading == true {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                note(tab == .brief ? "No brief yet" : (running ? "No report yet" : "No report"), color: Palette.muted)
            }
        }
        .overlay(alignment: .topTrailing) {
            if doc?.loading == true, doc?.text != nil {
                ProgressView().controlSize(.mini).padding(10)
            }
        }
        .background(Palette.pane)
        .task(id: key) { await app.loadRemoteDoc(node: node, tab: tab, key: key) }
    }

    private var running: Bool {
        switch node.state {
        case .thinking, .working, .waiting, .needsInput: true
        default: false
        }
    }

    private var key: String {
        let r = node.remote
        let path = (tab == .brief ? r?.briefPath : r?.resultPath) ?? ""
        return "\(path)|\(r?.turn ?? 0)|\(running)"
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Markdown made readable: headings bold, code fences monospaced, inline marks parsed,
/// line breaks kept. One Text, so all of it selects together.
struct MarkdownText: View {
    var text: String

    var body: some View {
        Text(Self.render(text))
            .font(.system(size: 12))
            .foregroundStyle(Palette.text.opacity(0.9))
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func render(_ text: String) -> AttributedString {
        var out = AttributedString()
        var inFence = false
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            // Fence lines themselves are dropped, with their line break.
            if s.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !first { out += AttributedString("\n") }
            first = false
            if inFence {
                var a = AttributedString(s)
                a.font = .system(size: 11.5, design: .monospaced)
                out += a
                continue
            }
            let hashes = s.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, s.dropFirst(hashes).first == " " {
                var a = (try? AttributedString(markdown: String(s.dropFirst(hashes + 1)), options: options))
                    ?? AttributedString(String(s.dropFirst(hashes + 1)))
                a.font = .system(size: hashes == 1 ? 14 : 12.5, weight: .semibold)
                out += a
                continue
            }
            out += (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        }
        return out
    }
}

// MARK: - Approvals

/// "Waiting on you": what the worker wants to do, and Allow or Deny. Buttons only,
/// so a stray Enter in a terminal never answers it.
struct ApprovalCard: View {
    @EnvironmentObject private var app: AppState
    var node: AgentNode
    var ask: PermissionAsk
    var send: PermissionSend?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10))
                Text("Waiting on you")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 6)
                Text(ask.at, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.faint)
            }
            .foregroundStyle(Palette.connecting)
            Text(ask.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let d = ask.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                ScrollView {
                    Text(d)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.text.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 84)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.window.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.border))
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ApprovalButtons(nodeID: node.id, send: send)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.connecting.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.connecting.opacity(0.35)))
    }
}

/// Allow and Deny, or where the answer is at.
struct ApprovalButtons: View {
    @EnvironmentObject private var app: AppState
    var nodeID: String
    var send: PermissionSend?

    var body: some View {
        HStack(spacing: 6) {
            switch send {
            case .sending:
                Text("Sending...").foregroundStyle(Palette.muted)
            case .sent(let allow):
                Text(allow ? "Allowed, waiting on the worker" : "Denied, waiting on the worker").foregroundStyle(Palette.muted)
            case nil:
                EmptyView()
            }
            Group {
                Button("Deny") { app.answerPermission(nodeID: nodeID, allow: false) }
                    .buttonStyle(ChromeButtonStyle())
                Button("Allow") { app.answerPermission(nodeID: nodeID, allow: true) }
                    .buttonStyle(ChromeButtonStyle(active: true, tint: Palette.connecting))
            }
            .opacity(send == nil ? 1 : 0.45)
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .disabled(send != nil)
    }
}

/// Every approval the project is waiting on, over the canvas, so nobody has to open
/// a card to answer.
struct PendingApprovals: View {
    @ObservedObject var orch: ProjectOrchestrator

    var body: some View {
        PendingApprovalList(orch: orch, graph: orch.shown)
    }
}

private struct PendingApprovalList: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var orch: ProjectOrchestrator
    @ObservedObject var graph: AgentGraph
    private let shown = 3

    var body: some View {
        let pending = app.pendingPermissions
        if !pending.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(pending.prefix(shown).enumerated()), id: \.element.id) { i, node in
                    if i > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    row(node)
                }
                if pending.count > shown {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    Text("\(pending.count - shown) more waiting")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
            }
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.connecting.opacity(0.4)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .padding(.horizontal, 220)
            .padding(.top, 10)
            .transition(.opacity)
        }
    }

    private func row(_ node: AgentNode) -> some View {
        let ask = node.remote?.permission
        let host = app.host(node.remote?.host ?? node.hostId)
        return HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
                .foregroundStyle(Palette.connecting)
            Button { app.expandNode(node.id) } label: {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    if let host { HostBadge(label: HostBadge.label(host, id: host.id), accent: Palette.accent(host)) }
                }
            }
            .buttonStyle(.plain)
            .help("Open \(node.name)")
            Text(ask?.text ?? "")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(ask?.detail ?? ask?.text ?? "")
            Spacer(minLength: 6)
            ApprovalButtons(nodeID: node.id, send: ask.flatMap { orch.permissionSends[$0.id] })
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }
}

// MARK: - Message box

/// Talks to a subagent through the orchestrator, as `@name text`.
struct NodeMessageBox: View {
    @EnvironmentObject private var app: AppState
    var node: AgentNode
    var selected: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
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
        .onAppear { if selected { focused = true } }
        .onChange(of: selected) { _, on in if on { focused = true } }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        app.sendToNode(node.id, text: t)
        text = ""
    }
}
