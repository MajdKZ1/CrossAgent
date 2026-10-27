import SwiftUI

struct TopBar: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text("CrossAgent")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.trailing, 4)
            ForEach(app.hosts) { host in HostChip(host: host) }
            Spacer(minLength: 8)

            SyncIndicator(sync: app.sync)

            Button { app.showNewPane.toggle() } label: {
                Label("New pane", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(ChromeButtonStyle())
            .help("New pane (⌘T)")
            .popover(isPresented: $app.showNewPane, arrowEdge: .bottom) {
                NewPanePopover().environmentObject(app)
            }

            Button { app.toggleBroadcast() } label: {
                Label("Broadcast", systemImage: "dot.radiowaves.left.and.right").labelStyle(.titleAndIcon)
            }
            .buttonStyle(ChromeButtonStyle(active: app.broadcast, tint: Palette.broadcast))
            .help("Type into every live pane (⌘⇧B)")

            Button { app.showStation.toggle() } label: {
                Label("Station", systemImage: "square.grid.2x2").labelStyle(.titleAndIcon)
            }
            .buttonStyle(ChromeButtonStyle(active: app.showStation, tint: Palette.text))
            .help("Viewing station (⌘⇧V)")
        }
        .padding(.leading, Palette.trafficLightInset)
        .padding(.trailing, 10)
        .frame(height: Palette.topBarHeight)
        .background(WindowDragArea())
    }
}

struct HostChip: View {
    @EnvironmentObject private var app: AppState
    var host: Host

    var body: some View {
        // paneStateVersion is read so the count refreshes when a pane connects or exits.
        let _ = app.paneStateVersion
        let live = app.liveCount(host: host)
        HStack(spacing: 6) {
            Dot(color: live > 0 ? Palette.accent(host) : Palette.faint, size: 6)
            Text(host.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.text.opacity(0.85))
            Text("\(live)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(live > 0 ? Palette.text.opacity(0.7) : Palette.faint)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Palette.chip))
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
        .help("\(live) live pane\(live == 1 ? "" : "s") on \(host.name)")
    }
}
