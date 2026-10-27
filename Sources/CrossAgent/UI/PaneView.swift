import AppKit
import SwiftUI

/// One pane. In a grid it is a quiet card with a slim header that fades back until
/// hovered. Alone (one pane, or maximized) it is just the terminal, edge to edge with
/// some padding, and the header floats in at the top right on hover.
struct PaneView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var pane: PaneSession
    var focused: Bool
    var hidden: Bool
    var solo = false

    @State private var hovering = false
    @State private var nearTop = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Palette.radius, style: .continuous) }
    /// The terminal's own background, so the padding around it reads as part of the terminal.
    private var fill: Color { Color(nsColor: ThemeTokens.shared.resolved.background) }
    private func animation(_ duration: Double) -> Animation? { reduceMotion ? nil : .easeOut(duration: duration) }

    var body: some View {
        VStack(spacing: 0) {
            if !solo {
                PaneHeader(pane: pane, lit: hovering || focused, showsButtons: hovering)
            }
            TerminalHost(terminal: pane.terminal, hidden: hidden)
                .padding(solo ? EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 12)
                              : EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 8))
                .overlay {
                    if pane.isExited { ExitedOverlay(pane: pane).transition(.opacity) }
                }
        }
        .background(shape.fill(fill))
        .overlay(alignment: .topTrailing) {
            if solo && (nearTop || pane.isExited) {
                PaneHeader(pane: pane, lit: true, showsButtons: true, floating: true)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .overlay(
            shape.strokeBorder(focused ? Palette.accent(pane.host).opacity(0.6) : Palette.border.opacity(0.7), lineWidth: 1)
                .opacity(solo ? 0 : 1)
                .allowsHitTesting(false)
        )
        .contentShape(shape)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                if !hovering { hovering = true }
                let top = p.y < 40
                if top != nearTop { nearTop = top }
            case .ended:
                hovering = false
                nearTop = false
            }
        }
        .simultaneousGesture(TapGesture().onEnded { app.focus(pane.id) })
        .opacity(hidden ? 0 : 1)
        .allowsHitTesting(!hidden)
        .animation(animation(0.12), value: pane.isExited)
        .animation(animation(0.1), value: focused)
        .animation(animation(0.15), value: nearTop)
    }
}

struct PaneHeader: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var pane: PaneSession
    /// Full strength while hovered or focused, faded back otherwise.
    var lit = true
    var showsButtons = true
    /// A compact capsule over a solo terminal instead of a row above it.
    var floating = false

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
            Dot(color: dotColor, size: 6)
            Group {
                Text(pane.host.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.text)
                if !floating { ModeBadge(mode: pane.mode) }
                Text(pane.session)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(lit ? 1 : 0.55)
            if !floating { Spacer(minLength: 4) }
            buttons
                .opacity(showsButtons ? 1 : 0)
                .allowsHitTesting(showsButtons)
        }
        .padding(.leading, floating ? 9 : 10)
        .padding(.trailing, floating ? 3 : 5)
        .frame(height: floating ? 24 : 24)
        .background {
            if floating {
                Capsule(style: .continuous).fill(Palette.raised.opacity(0.92))
                    .overlay(Capsule(style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.toggleMaximize(pane.id) }
        .contextMenu { menu }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: lit)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsButtons)
    }

    private var buttons: some View {
        HStack(spacing: 1) {
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
        Button("Find…") { pane.terminal.showFind() }
        Button("Clear") { pane.clearScrollback() }
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
