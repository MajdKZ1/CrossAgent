import SwiftUI

/// Compact Super-Max readout for the top bar: "16c/24t 23% · 30/64 GB". Opens the
/// Activity tab. Uses the shared monitor, so it adds no sampling of its own.
struct SuperMaxReadout: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var monitor = ActivityMonitor.shared

    var body: some View {
        Button { app.open(.activity) } label: {
            Hover { hovering in
                SuperMaxReadoutLabel(model: SuperMax(hosts: monitor.hosts)).equatable()
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.chipHover : .clear))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onAppear { monitor.start(hosts: app.hosts) }
        .onDisappear { monitor.stop() }
    }
}

/// Equatable on the text it shows, so samples that don't move a rounded number don't redraw it.
private struct SuperMaxReadoutLabel: View, Equatable {
    let cores: String
    let cpu: String
    let cpuLevel: Int?
    let mem: String
    let help: String

    init(model m: SuperMax) {
        cores = m.threads > 0 ? SuperMaxFormat.coresThreads(m.cores, m.threads, compact: true) : "--"
        cpu = SuperMaxFormat.percent(m.cpu)
        cpuLevel = m.cpu.map(LoadLevel.cpu)
        mem = m.memTotal > 0 ? SuperMaxFormat.memPair(m.memUsed, m.memTotal, compact: true) : "--"
        let parts = m.machines.map { x in
            x.online ? "\(x.name) \(SuperMaxFormat.percent(x.cpu)), \(x.memUsed.map { SuperMaxFormat.memPair($0, x.memTotal) } ?? "--")"
                : "\(x.name) offline"
        }
        help = "Super-Max Computer: \(m.online) of \(m.machines.count) online. " + parts.joined(separator: "; ")
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(cores).foregroundStyle(Palette.muted)
            Text(cpu).foregroundStyle(cpuLevel.map(ActivityColor.level) ?? Palette.faint)
            Text("·").foregroundStyle(Palette.faint)
            Text(mem).foregroundStyle(Palette.text)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .help(help)
    }
}
