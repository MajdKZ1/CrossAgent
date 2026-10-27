import AppKit
import SwiftUI

/// "Add a remote machine": ssh target, name, id, a Test button, Add and Skip. Shown on
/// first run while only this Mac is set up, and from Add Remote Machine... in the menu.
/// A new host is live right away: every window, monitor and orchestrator gets it.
@MainActor
final class HostSetupWindow: NSObject, NSWindowDelegate {
    static let shared = HostSetupWindow()
    private(set) var window: NSWindow?

    /// First run: nothing remote yet and the sheet was never skipped.
    func showIfNeeded(hosts: [Host]) {
        if HostStore.needsSetup(hosts) { show(firstRun: true) }
    }

    /// `target` prefills the ssh target and `test` runs Test right away (for automation).
    func show(firstRun: Bool = false, target: String = "", test: Bool = false) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = HostSetupView(firstRun: firstRun, taken: Set(HostStore.load().map(\.id)),
                                 initialTarget: target, testOnOpen: test) { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(Palette.raised)
        w.contentView = hosting
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct HostSetupView: View {
    let firstRun: Bool
    let taken: Set<String>
    var initialTarget = ""
    var testOnOpen = false
    let done: () -> Void

    @State private var target = ""
    @State private var name = ""
    @State private var id = ""
    @State private var idEdited = false
    @State private var probe: HostProbe.Result?
    @State private var testing = false
    @State private var added: String?
    @State private var error = ""

    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var targetOK: Bool { HostStore.isValidTarget(trimmedTarget) }
    private var idOK: Bool { HostStore.isValidID(id) && !taken.contains(id) }
    private var canAdd: Bool { targetOK && idOK && !trimmedName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let added {
                addedView(added)
            } else {
                form
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(width: 380)
        .background(Palette.raised)
        .onAppear {
            guard !initialTarget.isEmpty else { return }
            target = initialTarget
            if testOnOpen { DispatchQueue.main.async(execute: test) }
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add a remote machine")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text(firstRun ? "Run Claude on another box over ssh. Skip it and add one later from the app menu."
                          : "Anything you can ssh into without a password prompt.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        field("SSH target", text: $target, placeholder: "pc or me@host", ok: target.isEmpty || targetOK,
              hint: target.isEmpty || targetOK ? "An alias from ~/.ssh/config, or user@host" : "No spaces, can't start with -")
            .onChange(of: target) { _, new in
                probe = nil
                if name.isEmpty || name == autoName(target: oldTarget) { name = autoName(target: new) }
                oldTarget = new
            }
        field("Name", text: $name, placeholder: "Linux PC", ok: true, hint: nil)
            .onChange(of: name) { _, new in
                if !idEdited { id = HostStore.makeID(name: new.isEmpty ? trimmedTarget : new, taken: taken) }
            }
        field("Id", text: Binding(get: { id }, set: { id = $0; idEdited = true }), placeholder: "pc",
              ok: id.isEmpty || idOK,
              hint: id.isEmpty || idOK ? "Used in session names" : (taken.contains(id) ? "Already taken" : "Letters, digits, - and _ only, up to 40"))
        probeLine
        if !error.isEmpty {
            Text(error).font(.system(size: 11)).foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 6) {
            Button(testing ? "Testing..." : "Test", action: test)
                .buttonStyle(ChromeButtonStyle())
                .disabled(!targetOK || testing)
            Spacer()
            Button("Skip", action: skip)
                .buttonStyle(ChromeButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Add", action: add)
                .buttonStyle(ChromeButtonStyle(active: true, tint: Palette.primary))
                .disabled(!canAdd)
                .keyboardShortcut(.defaultAction)
        }
    }

    @State private var oldTarget = ""

    private func autoName(target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespaces)
        return String(t.split(separator: "@").last ?? Substring(t))
    }

    @ViewBuilder private var probeLine: some View {
        if let probe {
            if probe.reachable {
                HStack(spacing: 10) {
                    check("Connected", true)
                    check("tmux", probe.tmux)
                    check("claude", probe.claude)
                }
                if !probe.tmux {
                    Text("No tmux there, so sessions end when the window closes.")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.warning)
                }
            } else {
                Text("Couldn't connect: \(probe.error)")
                    .font(.system(size: 11)).foregroundStyle(Palette.danger)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func check(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Palette.success : Palette.danger)
            Text(label).foregroundStyle(Palette.text)
        }
        .font(.system(size: 11))
    }

    private func addedView(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Added \(label)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text("It's in the New pane list now.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            HStack(spacing: 6) {
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(ChromeButtonStyle(active: true, tint: Palette.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, ok: Bool, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Palette.faint)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(ok ? Palette.border : Palette.danger.opacity(0.7), lineWidth: 1))
                .autocorrectionDisabled()
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(ok ? Palette.faint : Palette.danger)
            }
        }
    }

    private func test() {
        guard targetOK, !testing else { return }
        let t = trimmedTarget
        testing = true
        probe = nil
        Task {
            let r = await HostProbe.run(target: t)
            testing = false
            if t == trimmedTarget { probe = r }
        }
    }

    private func skip() {
        UserDefaults.standard.set(true, forKey: HostStore.setupDismissedKey)
        done()
    }

    private func add() {
        guard canAdd else { return }
        let remotes = taken.count
        let host = Host(id: id, name: trimmedName, type: .ssh, target: trimmedTarget,
                        accent: HostStore.accents[max(0, remotes - 1) % HostStore.accents.count])
        do {
            try HostStore.add(host)
            UserDefaults.standard.set(true, forKey: HostStore.setupDismissedKey)
            added = host.name
            ProjectWindows.shared.reloadHosts()
        } catch {
            self.error = switch error as? HostStore.AddError {
            case .duplicateID?: "That id is already in hosts.json"
            case .unreadable?: "Couldn't read hosts.json, fix or move it and try again"
            default: "Couldn't save hosts.json"
            }
        }
    }
}
