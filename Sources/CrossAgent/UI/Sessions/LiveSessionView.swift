import SwiftUI

/// A Claude Code session CrossAgent has no terminal for, read only: its conversation
/// following the transcript live, or its agents on the canvas. An ended one can be
/// continued here. Follows only while its tab shows.
struct LiveSessionView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var discovery = SessionDiscovery.shared
    @StateObject private var feed: SessionFeed
    var tab: Tab
    var hostId: String
    var sessionId: String
    var selected: Bool

    @State private var showAgents = false
    /// Graph node whose lines the conversation is narrowed to.
    @State private var filter: String?
    @State private var positions: [String: CGPoint] = [:]
    @State private var confirmOverride = false
    @State private var following = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Palette.radius, style: .continuous) }

    init(tab: Tab, host: String, sessionId: String, selected: Bool) {
        self.tab = tab
        hostId = host
        self.sessionId = sessionId
        self.selected = selected
        _feed = StateObject(wrappedValue: SessionFeed.feed(host: host, sessionId: sessionId))
    }

    var body: some View {
        let session = discovery.session(host: hostId, sessionId: sessionId)
        let blocker = app.continueBlocker(host: hostId, sessionId: sessionId, feedStatus: feed.status)
        VStack(spacing: 0) {
            header(session, blocker: blocker)
            if let blocker { notice(blocker) }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ZStack {
                ConversationList(feed: feed, filter: filter, clearFilter: { filter = nil })
                    .opacity(showAgents ? 0 : 1)
                    .allowsHitTesting(!showAgents)
                if showAgents && selected { canvas }
            }
        }
        .background(shape.fill(Palette.pane))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.border, lineWidth: 1).allowsHitTesting(false))
        .onAppear { follow(selected) }
        .onChange(of: selected) { _, on in follow(on) }
        .onDisappear { follow(false) }
        .alert("Continue anyway?", isPresented: $confirmOverride) {
            Button("Continue here") { continueHere(force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If it's still open somewhere, two copies will write to the same conversation.")
        }
    }

    /// Feed and discovery run only while the tab shows.
    private func follow(_ on: Bool) {
        guard on != following else { return }
        following = on
        if on {
            feed.retain()
            discovery.addViewer()
        } else {
            feed.release()
            discovery.removeViewer()
        }
    }

    // MARK: Header

    private func header(_ s: ClaudeSession?, blocker: String?) -> some View {
        let host = app.host(hostId)
        let status = s?.status ?? feed.status
        return HStack(spacing: 8) {
            Dot(color: host.map(Palette.accent) ?? Palette.faint, size: 7)
            Text(s.map { AppState.shortTitle($0.title) } ?? app.title(of: tab))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(caption(s, host: host, status: status, now: ctx.date))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if status != .ended {
                HStack(spacing: 5) {
                    SessionDot(status: status, size: 6)
                    Text(SessionLook.word(status))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SessionLook.color(status))
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button("Conversation") { showAgents = false }
                    .buttonStyle(ChromeButtonStyle(active: !showAgents, tint: Palette.primary))
                Button(agentsLabel) { showAgents = true }
                    .buttonStyle(ChromeButtonStyle(active: showAgents, tint: Palette.primary))
            }
            Button("Continue here") { continueHere(force: false) }
                .buttonStyle(ChromeButtonStyle(active: blocker == nil, tint: Palette.primary))
                .disabled(blocker != nil || app.project == nil)
                .help(blocker ?? "Resume this conversation in a tmux session here, on the same host")
        }
        .padding(.horizontal, 12)
        .frame(height: Palette.headerHeight + 6)
    }

    private var agentsLabel: String {
        let n = feed.graph.nodes.count - 1
        return n > 0 ? "Agents \(n)" : "Agents"
    }

    private func caption(_ s: ClaudeSession?, host: Host?, status: ClaudeSessionStatus, now: Date) -> String {
        let on = host?.name ?? hostId
        if status == .ended {
            let last = s?.lastActivity ?? feed.items.last?.at
            return last.map { "Ended \(SessionLook.ago($0, now: now)) on \(on)" } ?? "Ended, on \(on)"
        }
        guard let s, s.launcher != .ended else { return "Watching, on \(on)" }
        let place = s.launcher == .other ? "a terminal" : s.launcher.label
        return "Watching, running in \(place) on \(on)"
    }

    static let wrapperTip = "Tip: sessions started with the CrossAgent claude wrapper can be used from both places."

    private func notice(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                Text(Self.wrapperTip)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("I've closed it") { confirmOverride = true }
                .buttonStyle(ChromeButtonStyle())
                .disabled(app.project == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.warning.opacity(0.06))
    }

    private func continueHere(force: Bool) {
        let cwd = discovery.session(host: hostId, sessionId: sessionId)?.cwd
        app.continueClaudeSession(host: hostId, sessionId: sessionId, cwd: cwd, force: force)
    }

    // MARK: Canvas

    private var canvas: some View {
        OrchestratorView(graph: feed.graph, hosts: app.hosts, positions: $positions, actions: OrchestratorActions(
            expand: { id in
                filter = id == AgentGraph.orchestratorID ? nil : id
                showAgents = false
            },
            clearFinished: { feed.graph.clearFinished() }))
    }
}

// MARK: - Conversation

/// The transcript as a lazy list. Sticks to the bottom while the user is there.
private struct ConversationList: View {
    @ObservedObject var feed: SessionFeed
    var filter: String?
    var clearFilter: () -> Void
    @State private var atBottom = true

    var body: some View {
        let rows = Self.rows(feed, filter: filter)
        VStack(spacing: 0) {
            if let filter { filterBar(filter) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { r in
                            ItemRow(row: r).equatable()
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .overlay {
                    if rows.isEmpty {
                        Text(filter == nil ? "Nothing in this conversation yet" : "Nothing from this agent yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.faint)
                    }
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: rows.last?.id) { _, _ in
                    if atBottom { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .onChange(of: filter) { _, _ in
                    atBottom = true
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
        }
    }

    private static let bottom = "bottom"

    private func filterBar(_ id: String) -> some View {
        HStack(spacing: 8) {
            Text("Only \(feed.graph.nodes[id]?.name ?? "this agent")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.text)
            Button("Show all", action: clearFilter)
                .buttonStyle(ChromeButtonStyle())
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Palette.chip)
    }

    /// Items as rows, tagged with their subagent's name where a run of its lines starts.
    static func rows(_ feed: SessionFeed, filter: String?) -> [ItemRowModel] {
        var out: [ItemRowModel] = []
        out.reserveCapacity(feed.items.count)
        var lastAgent: String?
        var nodeCache: [String: String?] = [:]
        func node(_ aid: String) -> String? {
            if let n = nodeCache[aid] { return n }
            let n = feed.nodeId(forAgent: aid) ?? (feed.graph.nodes[aid] != nil ? aid : nil)
            nodeCache[aid] = n
            return n
        }
        for item in feed.items {
            if item.kind == .thinking { continue }
            let nid = item.agentId.flatMap(node)
            if let filter, nid != filter, item.toolUseId != filter { continue }
            var tag: String?
            if let aid = item.agentId, aid != lastAgent {
                tag = nid.flatMap { feed.graph.nodes[$0]?.name } ?? "agent"
            }
            lastAgent = item.agentId
            out.append(ItemRowModel(item: item, nested: item.agentId != nil && filter == nil, tag: filter == nil ? tag : nil))
        }
        return out
    }
}

struct ItemRowModel: Identifiable, Equatable {
    var item: TranscriptItem
    /// From a subagent: indented under the main thread.
    var nested: Bool
    /// The subagent's name, on the first of its lines in a run.
    var tag: String?
    var id: String { item.id + (item.agentId ?? "") }
}

private struct ItemRow: View, Equatable {
    var row: ItemRowModel

    var body: some View {
        let it = row.item
        VStack(alignment: .leading, spacing: 3) {
            if let tag = row.tag {
                Text(tag)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                    .padding(.horizontal, 6)
                    .frame(height: 15)
                    .background(Capsule().fill(Palette.primary.opacity(0.12)))
                    .padding(.top, 6)
            }
            content(it)
        }
        .padding(.leading, row.nested ? 14 : 0)
        .overlay(alignment: .leading) {
            if row.nested { Rectangle().fill(Palette.primary.opacity(0.25)).frame(width: 1.5) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(_ it: TranscriptItem) -> some View {
        switch it.kind {
        case .user:
            Text(it.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .lineLimit(row.nested ? 4 : 40)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
                .padding(.top, 12)
                .padding(.bottom, 4)
        case .assistant:
            Text(it.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 5)
        case .thinking:
            Text(it.text)
                .font(.system(size: 11).italic())
                .foregroundStyle(Palette.faint)
                .lineLimit(3)
                .padding(.vertical, 3)
        case .toolUse:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(it.tool ?? "Tool")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(it.isError ? Palette.danger : Palette.text.opacity(0.85))
                Text(it.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.top, 5)
            .padding(.bottom, 1)
        case .toolResult:
            Text(it.text.isEmpty ? "(no output)" : it.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(it.isError ? Palette.danger : Palette.faint)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(.leading, 12)
                .padding(.bottom, 3)
        case .system:
            Text(it.text)
                .font(.system(size: 10.5))
                .foregroundStyle(it.isError ? Palette.danger : Palette.faint)
                .lineLimit(3)
                .padding(.vertical, 3)
        }
    }
}
