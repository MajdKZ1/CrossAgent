import AppKit
import SwiftUI

// MARK: - Root

/// Put on each SwiftUI root (main window, Settings, extra windows). Palette reads are
/// already tracked per view through ThemeTokens, so this only makes sure the store is
/// loaded and hands down the theme's accent as the tint. No `.id`, so no state is lost.
struct ThemedRoot: ViewModifier {
    @ObservedObject private var store = ThemeStore.shared

    func body(content: Content) -> some View {
        content
            .tint(Palette.primary)
            .environment(\.appTheme, store.current)
            .defaultAppStorage(AppDefaults.store)
    }
}

extension View {
    func themed() -> some View { modifier(ThemedRoot()) }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.fallback
}

extension EnvironmentValues {
    /// The current theme, for views that want the raw tokens.
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - Menu

/// Theme picker items for the View menu: `Menu("Theme") { ThemeMenuItems() }`.
struct ThemeMenuItems: View {
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        Picker("Theme", selection: Binding(get: { store.current.name }, set: { store.select(name: $0) })) {
            ForEach(store.all) { Text($0.name).tag($0.name) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button("Reveal Themes Folder") { ThemeStore.revealFolder() }
    }
}

// MARK: - Settings

/// The Themes pane for the Settings scene. Picking a theme applies it right away.
struct ThemeSettingsView: View {
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(store.all) { theme in
                        ThemeCard(theme: theme, selected: theme.name == store.current.name) {
                            store.select(name: theme.name)
                        }
                    }
                }
                .padding(2)
            }
            ForEach(store.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .lineLimit(2)
            }
            HStack {
                Text("Drop .json files in ~/.config/crossagent/themes. Edits show up live.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("Reveal Themes Folder") { ThemeStore.revealFolder() }
                    .buttonStyle(ChromeButtonStyle())
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
        .background(Palette.window)
        .themed()
    }
}

/// A theme drawn in its own colours: window, a pane with text, the ANSI row and the mascot.
struct ThemeCard: View {
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    private func c(_ hex: String) -> Color { Color(nsColor: NSColor(hex: hex)) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                HStack(spacing: 6) {
                    Text(theme.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.primary)
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Palette.radius, style: .continuous).fill(Palette.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Palette.radius, style: .continuous)
                    .strokeBorder(selected ? Palette.primary.opacity(0.8) : Palette.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach([theme.ui.accent, theme.ui.success, theme.ui.warning, theme.ui.danger], id: \.self) {
                        Circle().fill(c($0)).frame(width: 6, height: 6)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("$ claude").foregroundStyle(c(theme.terminal.foreground))
                    Text("reading files").foregroundStyle(c(theme.ui.muted))
                    Text("idle").foregroundStyle(c(theme.ui.faint))
                }
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c(theme.terminal.background)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(c(theme.ui.border)))
                VStack(spacing: 2) {
                    ansiRow(0..<8)
                    ansiRow(8..<16)
                }
            }
            mascot.padding(.top, 2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c(theme.ui.window)))
    }

    private func ansiRow(_ range: Range<Int>) -> some View {
        HStack(spacing: 2) {
            ForEach(range, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.terminal.ansi.indices.contains(i) ? c(theme.terminal.ansi[i]) : .clear)
                    .frame(height: 7)
            }
        }
    }

    private var mascot: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(c(theme.mascot.body))
            .frame(width: 16, height: 13)
            .overlay(
                HStack(spacing: 3) {
                    Capsule().fill(c(theme.mascot.eyes)).frame(width: 2, height: 4)
                    Capsule().fill(c(theme.mascot.eyes)).frame(width: 2, height: 4)
                }
            )
    }
}
