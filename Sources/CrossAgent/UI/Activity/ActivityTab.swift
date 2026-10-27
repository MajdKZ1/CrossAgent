import SwiftUI

/// Both machines side by side: CPU, memory, temperatures and the busiest sessions.
struct ActivityTab: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var monitor = ActivityMonitor.shared

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                ForEach(monitor.hosts) { h in
                    HostColumn(host: h) { name in app.openAgent(.session(host: h.hostId, name: name)) }.equatable()
                        .frame(minWidth: 300, maxWidth: .infinity)
                }
            }
            .padding(18)
        }
        .background(Palette.window)
        .onAppear { monitor.start(hosts: app.hosts, detail: true) }
        .onDisappear { monitor.stop(detail: true) }
    }
}

/// Equatable so a sample from one host doesn't rebuild the other column.
private struct HostColumn: View, Equatable {
    var host: HostActivity
    var openSession: (String) -> Void

    static func == (a: Self, b: Self) -> Bool { a.host == b.host }

    private var s: ActivitySample? { host.latest }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            cpuCard
            memoryCard
            if let s, !s.temps.isEmpty { tempsCard(s) }
            sessionsCard
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Dot(color: Color(nsColor: NSColor(hex: host.accent)), size: 8)
            Text(host.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
            Spacer()
            switch host.status {
            case .starting: Text("connecting").foregroundStyle(Palette.faint)
            case .live: Text("live").foregroundStyle(Palette.muted)
            case .unavailable(let why): Text(why).foregroundStyle(Palette.danger).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
    }

    // MARK: CPU

    private var cpuCard: some View {
        let cpu = s?.cpu
        let color = ActivityColor.level(LoadLevel.cpu(cpu ?? 0))
        return Card(title: "CPU") {
            HStack(alignment: .lastTextBaseline) {
                BigNumber(text: cpu.map(ActivityFormat.percent) ?? "--", color: cpu == nil ? Palette.faint : color)
                Spacer()
                if let s, !s.clusters.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(s.clusters, id: \.name) { c in
                            Text("\(c.name) \(ActivityFormat.percent(c.usage))")
                        }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                }
            }
            Sparkline(series: host.cpu, color: color, range: 0...1).equatable().frame(height: 34)
            if let s, !s.cores.isEmpty { CoreBars(sample: s) }
        }
    }

    // MARK: Memory

    private var memoryCard: some View {
        let frac = s?.memFraction ?? 0
        let color = ActivityColor.level(max(LoadLevel.mem(frac), s?.pressure?.rawValue ?? 0))
        return Card(title: "Memory") {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                if let s, s.memTotal > 0 {
                    BigNumber(text: ActivityFormat.gb(s.memUsed), color: color)
                    Text("/ \(ActivityFormat.bytes(s.memTotal))").font(.system(size: 13).monospacedDigit()).foregroundStyle(Palette.muted)
                } else {
                    BigNumber(text: "--", color: Palette.faint)
                }
                Spacer()
                if let p = s?.pressure {
                    HStack(spacing: 5) {
                        Dot(color: ActivityColor.level(p.rawValue), size: 6)
                        Text("pressure \(p.label)")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .help(s?.pressureDetail ?? "")
                }
            }
            Sparkline(series: host.mem, color: color, range: 0...1).equatable().frame(height: 34)
            HStack(spacing: 8) {
                Text("Swap").foregroundStyle(Palette.muted)
                Text(s.map { $0.swapTotal > 0 ? "\(ActivityFormat.bytes($0.swapUsed)) / \(ActivityFormat.bytes($0.swapTotal))" : "none in use" } ?? "--")
                    .foregroundStyle(Palette.text)
                Spacer()
                Sparkline(series: host.swap, color: Palette.muted, range: 0...Double(max(s?.swapTotal ?? 1, 1))).equatable()
                    .frame(width: 90, height: 14)
            }
            .font(.system(size: 11).monospacedDigit())
        }
    }

    // MARK: Temperatures

    private func tempsCard(_ s: ActivitySample) -> some View {
        Card(title: "Temperatures") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(s.temps, id: \.kind) { t in
                    TempTile(temp: t, history: host.temps[t.kind] ?? Series(),
                             detail: t.kind == .gpu ? s.gpu.map { "load \(ActivityFormat.percent($0))" } ?? t.detail : t.detail)
                }
            }
        }
    }

    // MARK: Sessions

    private var sessionsCard: some View {
        Card(title: "Top sessions") {
            if host.sessions.isEmpty {
                Text(host.status == .live ? "No ca-* sessions running" : "Waiting for data")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 2) {
                    ForEach(host.sessions) { load in
                        SessionRow(load: load) { openSession(load.name) }
                    }
                }
            }
        }
    }
}

// MARK: Pieces

private struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.faint)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Palette.radius, style: .continuous).fill(Palette.pane))
        .overlay(RoundedRectangle(cornerRadius: Palette.radius, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

private struct BigNumber: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
    }
}

/// One thin bar per core, grouped by cluster when the host has them.
private struct CoreBars: View {
    var sample: ActivitySample

    var body: some View {
        let groups: [(name: String?, cores: [Int])] = sample.clusters.isEmpty
            ? [(nil, Array(sample.cores.indices))]
            : sample.clusters.map { ($0.name, $0.cores) }
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(g.cores.filter { $0 < sample.cores.count }, id: \.self) { i in
                        bar(sample.cores[i])
                    }
                }
                .help(g.name ?? "")
            }
        }
        .frame(height: 18, alignment: .bottom)
    }

    private func bar(_ v: Double) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Palette.chip)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(ActivityColor.level(LoadLevel.cpu(v)))
                    .frame(height: max(1.5, 18 * v))
            }
            .frame(maxWidth: 10)
    }
}

private struct TempTile: View {
    var temp: TempGroup
    var history: Series
    var detail: String?

    var body: some View {
        let color = ActivityColor.level(LoadLevel.temp(temp))
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(temp.label).font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Text(ActivityFormat.degrees(temp.celsius))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
            }
            Sparkline(series: history, color: color, range: nil).equatable().frame(height: 20)
            Text(detail ?? " ")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
        }
    }
}

private struct SessionRow: View {
    var load: SessionLoad
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            Hover { hovering in
                HStack(spacing: 8) {
                    Image(systemName: load.claude ? "sparkle" : "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(load.claude ? Palette.primary : Palette.muted)
                        .frame(width: 14)
                    Text(load.name).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ActivityFormat.bytes(load.rssBytes)).foregroundStyle(Palette.muted)
                        .frame(width: 58, alignment: .trailing)
                    Text(String(format: "%.0f%%", load.cpu))
                        .foregroundStyle(ActivityColor.level(LoadLevel.cpu(load.cpu / 100)))
                        .frame(width: 44, alignment: .trailing)
                }
                .font(.system(size: 11).monospacedDigit())
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Palette.chipHover : .clear))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Open \(load.name)")
    }
}
