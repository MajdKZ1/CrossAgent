import SwiftUI

/// Words, colours and times for a Claude session, shared by the Sessions tab, the
/// station strip and the Live view header.
enum SessionLook {
    static func color(_ s: ClaudeSessionStatus) -> Color {
        switch s {
        case .running: Palette.primary
        case .waiting: Palette.warning
        case .idle: Palette.success
        case .ended: Palette.faint
        }
    }

    static func word(_ s: ClaudeSessionStatus) -> String {
        switch s {
        case .running: "running"
        case .waiting: "waiting for input"
        case .idle: "idle"
        case .ended: "ended"
        }
    }

    /// "12m" while it runs, "ended 3h ago" after.
    static func age(_ s: ClaudeSession, now: Date) -> String {
        if s.isRunning { return StationTile.format(now.timeIntervalSince(s.startedAt)) }
        return "ended " + ago(s.lastActivity, now: now)
    }

    static func ago(_ d: Date, now: Date) -> String {
        let t = now.timeIntervalSince(d)
        return t < 60 ? "just now" : short(t) + " ago"
    }

    /// One unit: 40s, 12m, 3h, 2d.
    static func short(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// Where it runs, for a row. Empty once ended.
    static func place(_ s: ClaudeSession) -> String {
        switch s.launcher {
        case .ended: ""
        case .tmux: s.tmuxSession.map { "tmux \($0)" } ?? "tmux"
        case .other: "terminal"
        default: s.launcher.label
        }
    }

    static func folder(_ cwd: String) -> String {
        cwd.isEmpty ? "?" : (cwd as NSString).lastPathComponent
    }
}

/// Status dot: filled while the process lives, a ring once it ended.
struct SessionDot: View {
    var status: ClaudeSessionStatus
    var size: CGFloat = 7

    var body: some View {
        let c = SessionLook.color(status)
        if status == .ended {
            Circle().strokeBorder(c, lineWidth: 1.2).frame(width: size, height: size)
        } else {
            Circle().fill(c).frame(width: size, height: size)
        }
    }
}

/// One session in a list. Equatable so a discovery poll only redraws rows that changed.
struct ClaudeSessionRow: View, Equatable {
    var session: ClaudeSession
    var host: Host?
    /// Minute resolution, so durations tick without a redraw every poll.
    var now: Date
    var compact = false
    var onOpen: () -> Void = {}

    static func == (a: ClaudeSessionRow, b: ClaudeSessionRow) -> Bool {
        a.session == b.session && a.host == b.host && a.now == b.now && a.compact == b.compact
    }

    var body: some View {
        let s = session
        Hover { hovering in
            HStack(spacing: 10) {
                SessionDot(status: s.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title)
                        .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                        .foregroundStyle(s.isRunning ? Palette.text : Palette.text.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    details
                }
                Spacer(minLength: 8)
                if let host {
                    HStack(spacing: 5) {
                        Dot(color: Palette.accent(host), size: 6)
                        Text(host.name)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: compact ? 36 : 42)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Palette.chipHover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
    }

    private var details: some View {
        let s = session
        var parts: [String] = []
        if compact { parts.append(SessionLook.folder(s.cwd)) }
        parts.append(SessionLook.age(s, now: now))
        let place = SessionLook.place(s)
        if !place.isEmpty { parts.append(place) }
        if s.subagentCount > 0 { parts.append(s.subagentCount == 1 ? "1 agent" : "\(s.subagentCount) agents") }
        // An ended row's age already says "ended".
        return HStack(spacing: 0) {
            if s.isRunning { Text(SessionLook.word(s.status) + "  ").foregroundStyle(SessionLook.color(s.status)) }
            Text(verbatim: parts.joined(separator: "  ·  ")).foregroundStyle(Palette.faint)
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
    }
}

/// Right click on a session row.
struct SessionMenu: View {
    @EnvironmentObject private var app: AppState
    var session: ClaudeSession

    var body: some View {
        Button(session.openMode == .watch ? "Watch" : "Open") { app.openClaudeSession(session) }
        if session.openMode != .transcript {
            Button("Open Live View") { app.openClaudeLive(host: session.hostId, sessionId: session.sessionId, title: session.title) }
        }
        Button("Continue Here") {
            app.continueClaudeSession(host: session.hostId, sessionId: session.sessionId, cwd: session.cwd)
        }
        .disabled(session.isRunning || app.project == nil)
        Divider()
        Button("Copy Session ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.sessionId, forType: .string)
        }
    }
}

/// Discovery's host problems, quiet: "Linux PC unreachable".
struct SessionHostErrors: View {
    @EnvironmentObject private var app: AppState
    var errors: [String: String]

    var body: some View {
        let list = errors.keys.sorted()
        if !list.isEmpty {
            HStack(spacing: 10) {
                ForEach(list, id: \.self) { id in
                    Text("\(app.host(id)?.name ?? id) unreachable")
                        .help(errors[id] ?? "")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.faint)
        }
    }
}

/// Keeps discovery polling while the view is up.
struct DiscoveryViewer: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { SessionDiscovery.shared.addViewer() }
            .onDisappear { SessionDiscovery.shared.removeViewer() }
    }
}
