import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            TabContent()
                .padding([.horizontal, .bottom], Palette.gap)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: app.selectedTabID)
        }
        .background(Palette.window)
        .modifier(FolderDrop())
        .overlay(alignment: .top) {
            if app.broadcast {
                Palette.broadcast.frame(height: 2).transition(.opacity)
            }
        }
        .overlay {
            if app.showRelayPicker { RelayPicker().transition(.opacity) }
        }
        .overlay {
            if let prompt = app.folderPrompt { FolderPromptCard(prompt: prompt).transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast { Toast(text: toast).transition(.opacity.combined(with: .offset(y: 6))) }
        }
        .animation(.easeOut(duration: 0.15), value: app.broadcast)
        .animation(.easeOut(duration: 0.12), value: app.showRelayPicker)
        .animation(.easeOut(duration: 0.12), value: app.folderPrompt)
        .animation(.easeOut(duration: 0.18), value: app.toast)
        .background(WindowAccessor { app.attach(window: $0) })
        .ignoresSafeArea()
    }
}

/// What the selected tab shows. Tabs with terminals (the pane grid, agent tabs) stay in
/// the hierarchy when hidden, so their terminals keep running, sized, with scrollback.
/// The rest hold no terminals and are built while they show.
struct TabContent: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        let selected = app.selectedTab
        ZStack {
            if app.project != nil {
                let on = app.mode == .panes
                PaneGrid()
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(on)
                if on && app.panes.isEmpty { EmptyState() }
            }
            ForEach(app.tabs.filter(\.isAgent)) { tab in
                let on = tab.id == app.selectedTabID
                AgentTabView(tab: tab, selected: on)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(on)
            }
            switch selected?.kind {
            case .welcome?: WelcomeView().transition(.opacity)
            case .station?:
                if let monitor = app.monitor { StationView(monitor: monitor).transition(.opacity) }
            case .orchestrator?: OrchestratorModeView().transition(.opacity)
            case .activity?: ActivityTab().transition(.opacity)
            case .dev(.orchestratorDemo)?: OrchestratorDemoTab()
            case .dev(.mascotGallery)?: MascotGalleryView()
            default: EmptyView()
            }
        }
    }
}

/// The project folder is missing on the host a new pane is for. Keys are routed here by `Shortcuts`.
struct FolderPromptCard: View {
    @EnvironmentObject private var app: AppState
    var prompt: FolderPrompt

    var body: some View {
        let tint = Palette.accent(prompt.host)
        let pcPath = app.project.map { "~/" + $0.pcRelativePath } ?? "the project folder"
        ZStack {
            Color.black.opacity(0.35)
                .onTapGesture { app.cancelFolderPrompt() }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Dot(color: tint, size: 6)
                    Text("No project folder on \(prompt.host.name) yet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.text)
                }
                Text(pcPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch prompt.phase {
                case .missing:
                    Text("Sync the project there, or open the pane in the home folder.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                case .syncing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting sync, the first one can take a minute")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                case .failed(let output):
                    ScrollView {
                        Text(output)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.danger)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                HStack(spacing: 6) {
                    Button("Cancel") { app.cancelFolderPrompt() }
                        .buttonStyle(ChromeButtonStyle())
                    Spacer()
                    Button("Open in home folder") { app.promptOpenInHome() }
                        .buttonStyle(ChromeButtonStyle())
                        .disabled(prompt.phase == .syncing)
                    Button(prompt.phase == .missing ? "Start sync" : "Retry sync") { app.promptStartSync() }
                        .buttonStyle(ChromeButtonStyle(active: true, tint: tint))
                        .disabled(prompt.phase == .syncing)
                }
                .padding(.top, 4)
                Text("↩ start sync   esc cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.faint)
            }
            .padding(14)
            .frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.085)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
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
