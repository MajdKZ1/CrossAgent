import SwiftUI

/// Orchestrator mode. Placeholder until the canvas lands.
struct OrchestratorModeView: View {
    @EnvironmentObject private var app: AppState
    @State private var hostID = ""

    var body: some View {
        let host = app.host(hostID) ?? app.hosts.first
        VStack(spacing: 12) {
            Text("Orchestrator canvas coming up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            if let o = app.orchestratorPane {
                Text("Running on \(o.host.name) in \(o.session)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
            HStack(spacing: 4) {
                ForEach(app.hosts) { h in
                    Button { hostID = h.id } label: {
                        HStack(spacing: 6) { Dot(color: Palette.accent(h), size: 6); Text(h.name) }
                    }
                    .buttonStyle(ChromeButtonStyle(active: h.id == host?.id, tint: Palette.accent(h)))
                }
            }
            Button("Start orchestrator") {
                if let host { app.startOrchestrator(hostID: host.id) }
            }
            .buttonStyle(ChromeButtonStyle(active: true, tint: host.map(Palette.accent) ?? Palette.text))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.window)
        .onAppear { if hostID.isEmpty { hostID = app.orchestratorPane?.host.id ?? app.lastHostID } }
    }
}
