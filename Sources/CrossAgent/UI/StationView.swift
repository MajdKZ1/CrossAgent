import SwiftUI

/// The viewing station: every `ca-*` tmux session on every host, live, as a wall of tiles.
struct StationView: View {
    @ObservedObject var monitor: TmuxMonitor
    @EnvironmentObject var app: AppState

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
            externalStrip
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

    @ViewBuilder private var externalStrip: some View {
        let ext = app.hosts.flatMap { monitor.external[$0.id] ?? [] }
        if !ext.isEmpty {
            HStack(spacing: Palette.gap) {
                Text("Outside tmux")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .padding(.leading, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Palette.gap) {
                        ForEach(ext) { e in externalChip(e) }
                    }
                }
            }
            .frame(height: 30)
        }
    }

    private func externalChip(_ e: ExternalClaude) -> some View {
        let host = app.host(e.hostId)
        return HStack(spacing: 6) {
            Dot(color: host.map(Palette.accent) ?? Palette.muted, size: 6)
            Text(host?.name ?? e.hostId).foregroundStyle(Palette.muted)
            Text(verbatim: "pid \(e.pid)").foregroundStyle(Palette.text)
            if let cwd = e.cwd {
                Text(Self.abbreviate(cwd)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            Text(StationTile.format(e.elapsed)).foregroundStyle(Palette.faint)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.pane))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .help("Claude Code not running in a ca-* tmux session, so it cannot be attached")
    }

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

    private static func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/(Users|home)/[^/]+"#, with: "~", options: .regularExpression)
    }
}
