import SwiftUI

/// Compact live readout for the tab strip: "Mac 12% 61°  PC 4% 48°". Opens the Activity tab.
struct ActivityReadout: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var monitor = ActivityMonitor.shared

    var body: some View {
        Button { app.open(.activity) } label: {
            Hover { hovering in
                HStack(spacing: 10) {
                    ForEach(monitor.hosts) { h in item(h) }
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.chipHover : .clear))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Activity")
        .onAppear { monitor.start(hosts: app.hosts) }
        .onDisappear { monitor.stop() }
    }

    private func item(_ h: HostActivity) -> some View {
        let s = h.latest
        let level = max(s?.cpu.map(LoadLevel.cpu) ?? 0, s?.cpuTemp.map(LoadLevel.temp) ?? 0)
        let live = h.status == .live
        return HStack(spacing: 4) {
            Dot(color: live ? ActivityColor.level(level) : Palette.faint, size: 6)
            Text(h.name).foregroundStyle(Palette.muted)
            if live, let s {
                Text(s.cpu.map(ActivityFormat.percent) ?? "...").foregroundStyle(Palette.text)
                if let t = s.cpuTemp { Text(ActivityFormat.degrees(t.celsius)).foregroundStyle(Palette.muted) }
            } else {
                Text(h.status == .starting ? "..." : "off").foregroundStyle(Palette.faint)
            }
        }
    }
}
