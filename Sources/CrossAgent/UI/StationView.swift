import SwiftUI

/// The viewing station: every `ca-*` tmux session on every host, live, as a wall of tiles.
struct StationView: View {
    @ObservedObject var monitor: TmuxMonitor
    @EnvironmentObject var app: AppState
    @ObservedObject private var discovery = SessionDiscovery.shared

    @State private var hoveredID: String?
    @State private var selectedID: String?
    @State private var columns = 1
    @FocusState private var focused: Bool

    private static let tileMinWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: Palette.gap) {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(app.hosts) { host in
                            section(host)
                        }
                        if allItems.isEmpty { emptyHint }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { columns = Self.columnCount(geo.size.width) }
                .onChange(of: geo.size.width) { _, w in columns = Self.columnCount(w) }
            }
            sessionsStrip
        }
        .background(Palette.window)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.escape) { app.showStation = false; return .handled }
        .onKeyPress(.return) { openSelected(); return .handled }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-columns); return .handled }
        .onKeyPress(.downArrow) { move(columns); return .handled }
        .onAppear {
            monitor.setActive(true)
            monitor.refreshNow()
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear { monitor.setActive(false) }
        .modifier(DiscoveryViewer())
    }

    // MARK: Items

    private func items(for host: Host) -> [StationItem] {
        let sessions = monitor.sessions[host.id] ?? []
        let names = Set(sessions.map(\.name))
        var out = sessions.map(StationItem.session)
        // Window panes whose process ended and whose tmux session is gone too.
        if monitor.reachable[host.id] == true {
            out += app.panes
                .filter { $0.host.id == host.id && $0.isExited && !names.contains($0.session) }
                .map(StationItem.exitedPane)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var allItems: [StationItem] { app.hosts.flatMap(items(for:)) }

    // MARK: Sections

    @ViewBuilder private func section(_ host: Host) -> some View {
        let list = items(for: host)
        VStack(alignment: .leading, spacing: Palette.gap) {
            hostHeader(host, count: list.count)
            if !list.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinWidth), spacing: Palette.gap)],
                          spacing: Palette.gap) {
                    ForEach(list) { item in
                        StationTile(item: item, host: host,
                                    selected: selectedID == item.id,
                                    hovered: hoveredID == item.id)
                            .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
                            .onTapGesture { open(item) }
                            .help("Open \(item.name) on \(host.name)")
                    }
                }
            }
        }
    }

    private func hostHeader(_ host: Host, count: Int) -> some View {
        HStack(spacing: 7) {
            Dot(color: Palette.accent(host), size: 7)
            Text(host.name).foregroundStyle(Palette.text).fontWeight(.medium)
            switch monitor.reachable[host.id] {
            case nil:
                Text("connecting").foregroundStyle(Palette.connecting.opacity(0.8))
            case false?:
                Text("\(host.id) unreachable: \(Self.shortError(monitor.lastError[host.id]))")
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            case true?:
                Text(count == 1 ? "1 session" : "\(count) sessions").foregroundStyle(Palette.faint)
            }
            Spacer()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 4)
        .frame(height: 22)
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Text("Nothing running")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text)
            Text("Press \u{2318}T to open a pane, or ask Claude to run the crossagent skill.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// Live Claude sessions in this project that aren't CrossAgent tiles already
    /// (Ghostty, Terminal, plain tmux, ssh ...). Same click as in the Sessions tab.
    @ViewBuilder private var sessionsStrip: some View {
        let live = discovery.sessions.filter { $0.isRunning && $0.launcher != .crossAgent && app.sessionInProject($0) }
        if !live.isEmpty {
            let shown = live.prefix(Self.stripMax)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Other Claude sessions here")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.faint)
                    Spacer()
                    Button(live.count > shown.count ? "All \(live.count)" : "Sessions") { app.open(.sessions) }
                        .buttonStyle(ChromeButtonStyle())
                }
                .padding(.horizontal, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Palette.gap)], spacing: 0) {
                    ForEach(Array(shown)) { s in
                        ClaudeSessionRow(session: s, host: app.host(s.hostId), now: Date(), compact: true) { app.openClaudeSession(s) }
                            .contextMenu { SessionMenu(session: s) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.pane))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            }
        }
    }

    private static let stripMax = 4

    // MARK: Actions

    private func open(_ item: StationItem) {
        selectedID = item.id
        switch item {
        case .session(let s): app.openFromStation(s)
        case .exitedPane(let p): app.openFromStation(pane: p)
        }
    }

    private func openSelected() {
        if let item = allItems.first(where: { $0.id == selectedID }) { open(item) }
    }

    private func move(_ delta: Int) {
        let list = allItems
        guard !list.isEmpty else { return }
        guard let cur = list.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = list.first?.id
            return
        }
        selectedID = list[min(max(cur + delta, 0), list.count - 1)].id
    }

    // MARK: Helpers

    private static func columnCount(_ width: CGFloat) -> Int {
        max(1, Int((width + Palette.gap) / (tileMinWidth + Palette.gap)))
    }

    private static func shortError(_ s: String?) -> String {
        let line = (s ?? "no response").split(separator: "\n").last.map(String.init) ?? "no response"
        return line.count > 120 ? String(line.prefix(120)) + "..." : line
    }
}
