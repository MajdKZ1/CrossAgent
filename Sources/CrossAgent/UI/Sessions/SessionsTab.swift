import SwiftUI

/// Every Claude Code session on every host, live and from the last few days, grouped
/// by folder. This project's by default, all of them with the toggle.
struct SessionsTab: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var discovery = SessionDiscovery.shared
    @AppStorage("sessions.allProjects") private var allProjects = false
    @State private var shownAt = Date()

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Palette.radius, style: .continuous) }

    var body: some View {
        let list = shown
        VStack(spacing: 0) {
            header(list)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let now = Date(timeIntervalSince1970: (ctx.date.timeIntervalSince1970 / 60).rounded(.down) * 60)
                if list.isEmpty {
                    empty(now: ctx.date)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Self.groups(list)) { g in
                                groupHeader(g)
                                ForEach(g.sessions) { s in
                                    ClaudeSessionRow(session: s, host: app.host(s.hostId), now: now) { app.openClaudeSession(s) }
                                        .equatable()
                                        .contextMenu { SessionMenu(session: s) }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .background(shape.fill(Palette.pane))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.border, lineWidth: 1).allowsHitTesting(false))
        .modifier(DiscoveryViewer())
        .onAppear { shownAt = Date() }
    }

    /// What the filter lets through, in discovery's order (running first, then recent).
    private var shown: [ClaudeSession] {
        guard !allProjects, app.project != nil else { return discovery.sessions }
        return discovery.sessions.filter { app.sessionInProject($0) }
    }

    private func header(_ list: [ClaudeSession]) -> some View {
        let running = list.filter(\.isRunning).count
        return HStack(spacing: 10) {
            Text("Sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text("\(running) running  ·  \(list.count - running) recent")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
            Spacer(minLength: 8)
            SessionHostErrors(errors: discovery.hostErrors)
            if app.project != nil {
                HStack(spacing: 2) {
                    Button("This project") { allProjects = false }
                        .buttonStyle(ChromeButtonStyle(active: !allProjects, tint: Palette.primary))
                    Button("All projects") { allProjects = true }
                        .buttonStyle(ChromeButtonStyle(active: allProjects, tint: Palette.primary))
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Palette.headerHeight + 6)
    }

    private func groupHeader(_ g: SessionGroup) -> some View {
        HStack(spacing: 7) {
            Text(g.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
            Text(g.path)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }

    private func empty(now: Date) -> some View {
        let looking = now.timeIntervalSince(shownAt) < 3 && discovery.sessions.isEmpty
        return VStack(spacing: 6) {
            Text(looking ? "Looking for sessions" : "No Claude sessions here yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text)
            if !looking {
                Text(allProjects || app.project == nil
                     ? "Sessions from the last \(discovery.recentDays) days on every host show up here."
                     : "Only this project's sessions show. Pick All projects to see the rest.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Folders in order of first appearance, so a folder with a running session leads.
    /// The same folder under each host's home (the Mac and its PC copy) is one group.
    static func groups(_ list: [ClaudeSession]) -> [SessionGroup] {
        var order: [String] = []
        var map: [String: SessionGroup] = [:]
        for s in list {
            let key = homeRelative(s.cwd)
            if map[key] == nil {
                order.append(key)
                map[key] = SessionGroup(id: key, name: SessionLook.folder(s.cwd), path: key, sessions: [])
            }
            map[key]!.sessions.append(s)
        }
        return order.compactMap { map[$0] }
    }

    static func homeRelative(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/(home/[^/]+|Users/[^/]+|root)(?=/|$)"#, with: "~", options: .regularExpression)
    }
}

struct SessionGroup: Identifiable {
    var id: String
    var name: String
    var path: String
    var sessions: [ClaudeSession]
}
