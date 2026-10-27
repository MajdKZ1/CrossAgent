import AppKit
import SwiftUI

/// Host, mode and optional session name. Opens focused on the name field with the
/// last used host picked, so ⌘T then Enter is a new pane right away.
struct NewPanePopover: View {
    @EnvironmentObject private var app: AppState
    @State private var hostID = ""
    @State private var mode: PaneMode = .claude
    @State private var name = ""
    @State private var keyMonitor: Any?
    @FocusState private var nameFocused: Bool

    private var host: Host? { app.host(hostID) ?? app.hosts.first }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameValid: Bool { trimmed.isEmpty || SessionName.isValid(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Host") {
                VStack(spacing: 2) {
                    ForEach(app.hosts) { h in hostRow(h) }
                }
            }
            section("Mode") {
                HStack(spacing: 4) {
                    ForEach(PaneMode.allCases, id: \.self) { m in
                        Button { mode = m } label: {
                            Text(m.label).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChromeButtonStyle(active: mode == m, tint: host.map(Palette.accent) ?? Palette.text))
                    }
                }
            }
            section("Session") {
                TextField(host.map { app.nextSessionName(host: $0) } ?? "", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(nameValid ? Palette.border : Palette.danger.opacity(0.7), lineWidth: 1))
                    .focused($nameFocused)
                    .onSubmit(create)
                Text(nameValid ? "Empty picks the next free name. Same name reattaches." : "Letters, digits, - and _ only, up to 40")
                    .font(.system(size: 10))
                    .foregroundStyle(nameValid ? Palette.faint : Palette.danger)
            }
            HStack {
                Text("↑↓ host   ⇥ mode   ↩ open")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.faint)
                Spacer()
                Button("Open", action: create)
                    .buttonStyle(ChromeButtonStyle(active: true, tint: host.map(Palette.accent) ?? Palette.text))
                    .disabled(!nameValid)
            }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear {
            hostID = app.lastHostID
            // The popover window is not key yet on appear, so focus on the next turn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
            installKeys()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if !app.showNewPane, let id = app.focusedID { app.focus(id) }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Palette.faint)
            content()
        }
    }

    private func hostRow(_ h: Host) -> some View {
        let selected = h.id == host?.id
        return Button { hostID = h.id } label: {
            HStack(spacing: 8) {
                Dot(color: Palette.accent(h))
                Text(h.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
                Text(h.isLocal ? "local" : (h.target ?? "ssh"))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.faint)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent(h))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.accent(h).opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func create() {
        guard nameValid, let host else { return }
        app.showNewPane = false
        app.requestPane(hostID: host.id, mode: mode, session: trimmed)
    }

    /// Arrows and Tab belong to the text field, so catch them first. Only installed while
    /// the popover is up, and the popover is the key window then.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        let hosts = app.hosts
        let host = $hostID, mode = $mode
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard flags.isEmpty || flags == .shift else { return event }
            let i = hosts.firstIndex { $0.id == host.wrappedValue } ?? 0
            switch event.keyCode {
            case 126: host.wrappedValue = hosts[(i - 1 + hosts.count) % hosts.count].id
            case 125: host.wrappedValue = hosts[(i + 1) % hosts.count].id
            case 48: mode.wrappedValue = mode.wrappedValue == .claude ? .shell : .claude
            default: return event
            }
            return nil
        }
    }
}
