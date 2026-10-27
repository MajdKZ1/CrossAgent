import AppKit
import SwiftUI

/// Shown with no project open: pick a folder or one of the recent ones.
struct WelcomeView: View {
    @EnvironmentObject private var app: AppState
    // Loaded here since the window can draw before the delegate sets the app icon.
    @State private var icon = AppDelegate.bundledIcon() ?? NSApp.applicationIconImage ?? NSImage()

    var body: some View {
        // Read here so the list refreshes when recents change (app publishes then).
        let recents = app.recentProjects
        VStack(spacing: 0) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .padding(.bottom, 14)
            Text("CrossAgent")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.text)
            Text("Pick a folder. Every pane, on every host, starts there.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.top, 6)
            Button { app.presentOpenPanel() } label: {
                Label("Open a project folder", systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(ChromeButtonStyle(active: true, tint: Palette.primary))
            .help("Open a project (⌘O), or drop a folder on the window")
            .padding(.top, 20)

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECENT")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, 10)
                        .padding(.bottom, 2)
                    ForEach(recents.prefix(6)) { r in RecentRow(recent: r) }
                }
                .frame(width: 380)
                .padding(.top, 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -Palette.topBarHeight / 2)
    }
}

struct RecentRow: View {
    @EnvironmentObject private var app: AppState
    var recent: RecentProject

    var body: some View {
        Hover { hovering in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Text(tildePath(recent.path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Button { app.removeRecent(path: recent.path) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                        .help("Remove from recents")
                } else {
                    Text(relativeTime(recent.lastOpened))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Palette.chipHover : .clear))
            .contentShape(Rectangle())
            .onTapGesture { app.switchProject(recent.url) }
        }
    }
}

/// "2 days ago", or "just now" under a minute.
func relativeTime(_ date: Date, now: Date = Date()) -> String {
    if now.timeIntervalSince(date) < 60 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: date, relativeTo: now)
}

/// Dropping a folder anywhere on the window opens it as the project.
struct FolderDrop: ViewModifier {
    @EnvironmentObject private var app: AppState
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ProjectStore.folderExists(url.standardizedFileURL.path) else { return }
                    DispatchQueue.main.async { app.switchProject(url) }
                }
                return true
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: Palette.radius, style: .continuous)
                        .strokeBorder(Palette.primary.opacity(0.6), lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: Palette.radius, style: .continuous)
                            .fill(Palette.primary.opacity(0.05)))
                        .padding(4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: targeted)
    }
}
