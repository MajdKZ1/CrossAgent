import SwiftUI

/// Top bar status for the Crossover Portal (Mutagen `ca-*` sessions): the Mac and PC
/// linked through the portal ring. In a project window it shows that project's portal,
/// dim when it has none. Hidden when Mutagen isn't installed and nothing is open.
struct SyncIndicator: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var sync: SyncMonitor
    /// Ring only, no "Portal" label, for narrow windows.
    var compact = false
    @State private var open = false

    var body: some View {
        if let look = PortalLook(app: app, sync: sync) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    PortalRing(state: look.state, size: 11, leading: look.mac, trailing: look.pc)
                    if !compact {
                        Text("Portal")
                            .foregroundStyle(look.othersNeedLook ? Palette.danger
                                : look.state == .off ? Palette.muted : Palette.text.opacity(0.85))
                    }
                }
            }
            .buttonStyle(ChromeButtonStyle())
            .help(look.help)
            .accessibilityLabel("Crossover Portal, \(look.words)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SyncPopover(sync: sync).environmentObject(app)
            }
        }
    }

    static func color(_ state: PortalRing.State) -> Color {
        switch state {
        case .off: Palette.faint
        case .steady, .crossing: Palette.muted
        case .syncing: Palette.warning
        case .conflict: Palette.danger
        }
    }
}

/// What the indicator and the popover header show, worked out from the monitor.
private struct PortalLook {
    var state: PortalRing.State
    var words: String
    var mac: Color
    var pc: Color
    /// This window's project, nil in the welcome window.
    var mine: SyncSession?
    var others: [SyncSession]
    var othersNeedLook: Bool
    var help: String

    @MainActor init?(app: AppState, sync: SyncMonitor) {
        let pcHost = app.hosts.first { !$0.isLocal }
        mac = app.hosts.first(where: \.isLocal).map(Palette.accent) ?? Palette.faint
        pc = pcHost.map(Palette.accent) ?? Palette.faint
        let pcName = pcHost?.name ?? "the PC"
        if let project = app.project {
            guard sync.installed || !sync.sessions.isEmpty else { return nil }
            let name = project.syncSessionName
            mine = sync.sessions.first { $0.name == name }
            others = sync.sessions.filter { $0.name != name }
            if let mine {
                let crossing = sync.isCrossing(mine)
                state = mine.portal(crossing: crossing)
                words = mine.portalWords(crossing: crossing)
                help = "Crossover Portal: \(words). \(project.name) on this Mac and \(pcName)"
            } else {
                state = .off
                words = "Off"
                help = "Crossover Portal is off for \(project.name)"
            }
        } else {
            guard !sync.sessions.isEmpty else { return nil }
            mine = nil
            others = sync.sessions
            let states = others.map { $0.portal(crossing: sync.isCrossing($0)) }
            state = [.conflict, .syncing, .crossing, .steady].first(where: states.contains) ?? .steady
            let n = others.count
            switch state {
            case .conflict: words = "Needs a look"
            case .syncing: words = "Catching up"
            case .crossing: words = "Files crossing"
            default: words = "In sync"
            }
            help = "Crossover Portal: \(n) open, \(words.lowercased())"
        }
        othersNeedLook = app.project != nil && state != .conflict && others.contains { $0.health == .problem }
        if othersNeedLook { help += ". Another Portal needs a look" }
    }
}

struct SyncPopover: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var sync: SyncMonitor

    var body: some View {
        if let look = PortalLook(app: app, sync: sync) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    PortalRing(state: look.state, size: 16, leading: look.mac, trailing: look.pc)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Crossover Portal")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.text)
                        Text(look.words)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SyncIndicator.color(look.state))
                    }
                    Spacer(minLength: 0)
                }
                if let mine = look.mine {
                    detail(mine)
                } else if let project = app.project {
                    let pc = app.hosts.first { !$0.isLocal }?.name ?? "the PC"
                    Text("No Portal for \(project.name) yet. Run \(Text("ca portal start").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.text)) in the project to mirror it to \(pc).")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !look.others.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(app.project == nil ? "PORTALS" : "OTHER PORTALS")
                            .font(.system(size: 9.5, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(Palette.faint)
                        ForEach(look.others) { s in other(s) }
                    }
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }

    /// The window's own portal: both ends, then anything that needs a look.
    private func detail(_ s: SyncSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let a = s.alpha { end(a) }
            if let b = s.beta { end(b) }
            trouble(s)
        }
    }

    private func end(_ e: SyncSession.Endpoint) -> some View {
        let local = e.host?.isEmpty ?? true
        let host = app.hosts.first { $0.isLocal == local }
        return HStack(spacing: 7) {
            Dot(color: host.map(Palette.accent) ?? Palette.faint, size: 6)
            Text(e.display)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func other(_ s: SyncSession) -> some View {
        let crossing = sync.isCrossing(s)
        let state = s.portal(crossing: crossing)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                PortalRing(state: state, size: 9)
                Text(s.project)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(s.portalWords(crossing: crossing))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SyncIndicator.color(state))
            }
            trouble(s).padding(.leading, 16)
        }
        .help([s.alpha?.display, s.beta?.display].compactMap { $0 }.joined(separator: "\n"))
    }

    @ViewBuilder private func trouble(_ s: SyncSession) -> some View {
        ForEach(s.conflictRoots, id: \.self) { root in
            Label(root.isEmpty ? "(root)" : root, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.danger)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        ForEach(Array(s.problems.prefix(3).enumerated()), id: \.offset) { _, p in
            Text(p)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.danger.opacity(0.85))
                .lineLimit(2)
        }
        if let e = s.error {
            Text(e)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.danger.opacity(0.85))
                .lineLimit(3)
        }
        if !s.conflictRoots.isEmpty {
            Text("See \(Text("ca portal conflicts").font(.system(size: 10, design: .monospaced)))")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
        }
    }
}
