import SwiftUI

/// Top bar status for Mutagen `ca-*` sync sessions. Hidden when there's nothing to show.
struct SyncIndicator: View {
    @ObservedObject var sync: SyncMonitor
    @State private var open = false

    var body: some View {
        if sync.installed && !sync.sessions.isEmpty {
            let count = sync.sessions.count
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Dot(color: Self.color(sync.health), size: 6)
                    Text(count > 1 ? "Sync \(count)" : "Sync")
                }
            }
            .buttonStyle(ChromeButtonStyle())
            .help(Self.summary(sync.health, count: count))
            .popover(isPresented: $open, arrowEdge: .bottom) { SyncPopover(sync: sync) }
        }
    }

    static func color(_ h: SyncHealth) -> Color {
        switch h {
        case .ok: return Palette.synced
        case .busy: return Palette.connecting
        case .problem: return Palette.danger
        }
    }

    static func summary(_ h: SyncHealth, count: Int) -> String {
        let s = "\(count) sync session\(count == 1 ? "" : "s")"
        switch h {
        case .ok: return "\(s), all synced"
        case .busy: return "\(s), syncing"
        case .problem: return "\(s), needs a look"
        }
    }
}

struct SyncPopover: View {
    @ObservedObject var sync: SyncMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SYNC")
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Palette.faint)
            ForEach(sync.sessions) { s in row(s) }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func row(_ s: SyncSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Dot(color: SyncIndicator.color(s.health), size: 6)
                Text(s.project)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text(s.statusWord)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            Group {
                if let a = s.alpha { Text(a.display) }
                if let b = s.beta { Text(b.display) }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.faint)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, 13)
            ForEach(s.conflictRoots, id: \.self) { root in
                Label(root.isEmpty ? "(root)" : root, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 13)
            }
            ForEach(Array(s.problems.prefix(3).enumerated()), id: \.offset) { _, p in
                Text(p)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.danger.opacity(0.85))
                    .lineLimit(2)
                    .padding(.leading, 13)
            }
            if let e = s.error {
                Text(e)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.danger.opacity(0.85))
                    .lineLimit(3)
                    .padding(.leading, 13)
            }
        }
    }
}
