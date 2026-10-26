import AppKit
import SwiftUI

struct PaneView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var pane: PaneSession
    var focused: Bool
    var hidden: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Palette.radius, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane)
            TerminalHost(terminal: pane.terminal, hidden: hidden)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .overlay {
                    if pane.isExited { ExitedOverlay(pane: pane).transition(.opacity) }
                }
        }
        .background(shape.fill(Palette.pane))
        .overlay(
            shape.strokeBorder(focused ? Palette.accent(pane.host).opacity(0.85) : Palette.border,
                               lineWidth: focused ? 1.5 : 1)
                .allowsHitTesting(false)
        )
        .contentShape(shape)
        .simultaneousGesture(TapGesture().onEnded { app.focus(pane.id) })
        .opacity(hidden ? 0 : 1)
        .allowsHitTesting(!hidden)
        .animation(.easeOut(duration: 0.12), value: pane.isExited)
        .animation(.easeOut(duration: 0.1), value: focused)
    }
}

struct PaneHeader: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var pane: PaneSession

    private var dotColor: Color {
        switch pane.state {
        case .connecting: Palette.connecting
        case .live: Palette.accent(pane.host)
        case .exited: Palette.exited
        }
    }

    private var targets: [PaneSession] { app.panes.filter { $0.id != pane.id && $0.isLive } }

    var body: some View {
        HStack(spacing: 7) {
            Dot(color: dotColor)
            Text(pane.host.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.text)
            ModeBadge(mode: pane.mode)
            Text(pane.session)
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            buttons
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: Palette.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.toggleMaximize(pane.id) }
        .contextMenu { menu }
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            Menu {
                if targets.isEmpty {
                    Text("No other live panes")
                } else {
                    Section("Relay selection to") {
                        ForEach(targets) { t in
                            Button("\(t.host.name)  \(t.session)") { app.relay(to: t.id, from: pane.id) }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Relay selection (⌘⇧R)")

            Button { app.reconnect(pane.id) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle())
                .help("Reconnect")

            Button {
                if NSEvent.modifierFlags.contains(.option) { app.kill(pane.id) } else { app.close(pane.id) }
            } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .help("Close pane, session keeps running (⌥ click kills the session)")
        }
    }

    @ViewBuilder private var menu: some View {
        Button(app.maximizedID == pane.id ? "Restore" : "Maximize") { app.toggleMaximize(pane.id) }
        Button("Reconnect") { app.reconnect(pane.id) }
        Divider()
        Button("Close Pane") { app.close(pane.id) }
        Button("Kill Session") { app.kill(pane.id) }
    }
}

struct ModeBadge: View {
    var mode: PaneMode

    var body: some View {
        Text(mode.label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
    }
}

struct ExitedOverlay: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var pane: PaneSession

    private var detail: String {
        if case .exited(let code?) = pane.state, code != 0 { return "Exited with code \(code). The tmux session may still be there." }
        return "The client exited. Reconnect reattaches its tmux session, or starts it fresh."
    }

    var body: some View {
        ZStack {
            Palette.pane.opacity(0.88)
            VStack(spacing: 10) {
                Text("Session ended")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("Reconnect") { app.reconnect(pane.id) }
                        .buttonStyle(ChromeButtonStyle(active: true, tint: Palette.accent(pane.host)))
                    Button("Close") { app.close(pane.id) }
                        .buttonStyle(ChromeButtonStyle())
                }
                .padding(.top, 2)
            }
            .padding(20)
        }
    }
}
