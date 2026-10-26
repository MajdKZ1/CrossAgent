import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ZStack {
                // The grid stays alive under the station so terminals keep running and sized.
                PaneGrid()
                    .opacity(app.showStation ? 0 : 1)
                    .allowsHitTesting(!app.showStation)
                if app.panes.isEmpty && !app.showStation { EmptyState() }
                if app.showStation, let monitor = app.monitor { StationView(monitor: monitor) }
            }
            .padding([.horizontal, .bottom], Palette.gap)
        }
        .background(Palette.window)
        .overlay(alignment: .top) {
            if app.broadcast {
                Palette.broadcast.frame(height: 2).transition(.opacity)
            }
        }
        .overlay {
            if app.showRelayPicker { RelayPicker().transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast { Toast(text: toast).transition(.opacity.combined(with: .offset(y: 6))) }
        }
        .animation(.easeOut(duration: 0.15), value: app.broadcast)
        .animation(.easeOut(duration: 0.12), value: app.showRelayPicker)
        .animation(.easeOut(duration: 0.18), value: app.toast)
        .background(WindowAccessor { app.attach(window: $0) })
        .ignoresSafeArea()
        .onChange(of: app.showStation) { _, on in
            // A hidden terminal must not keep eating keystrokes.
            if on { app.window?.makeFirstResponder(nil) } else if let id = app.focusedID { app.focus(id) }
        }
    }
}

struct Toast: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color(white: 0.11)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .padding(.bottom, 18)
            .allowsHitTesting(false)
    }
}

struct EmptyState: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.faint)
                .padding(.bottom, 4)
            Text("No panes yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text("Open Claude or a shell on any of your hosts.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                Button { app.showNewPane = true } label: { Label("New pane", systemImage: "plus") }
                    .buttonStyle(ChromeButtonStyle())
                Text("⌘T").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.faint)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pick where the focused pane's selection goes. Keys are routed here by `Shortcuts`.
struct RelayPicker: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let targets = app.relayTargets
        let preview = app.focused?.selectedText?
            .split(whereSeparator: \.isNewline).first.map(String.init)
        ZStack {
            Color.black.opacity(0.35)
                .onTapGesture { app.closeRelayPicker() }
            VStack(alignment: .leading, spacing: 8) {
                Text("Relay selection to")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(preview.map { "\"\($0)\"" } ?? "Nothing selected in this pane")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(preview == nil ? Palette.danger : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                VStack(spacing: 2) {
                    ForEach(Array(targets.enumerated()), id: \.element.id) { i, t in
                        row(i, t, selected: i == app.relayPickIndex)
                    }
                }
                .padding(.top, 2)
                Text("↑↓ or 1-9 to pick   ↩ send   esc cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.faint)
            }
            .padding(14)
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.085)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
    }

    private func row(_ i: Int, _ t: PaneSession, selected: Bool) -> some View {
        Button { app.pickRelay(i) } label: {
            HStack(spacing: 8) {
                Text(i < 9 ? "\(i + 1)" : " ")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.faint)
                    .frame(width: 12)
                Dot(color: Palette.accent(t.host))
                Text(t.host.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
                Text(t.session).font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                ModeBadge(mode: t.mode)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Palette.accent(t.host).opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
