import AppKit

// Contract for the theme system. A theme drives the whole app and the terminals.
// Everyone reads colours through `Palette` (SwiftUI) and `Theme` (terminals); the theme
// work makes those follow `ThemeStore.shared.current`. Layer based views (canvas,
// mascot) listen for `.crossAgentThemeChanged` and recolour themselves.

struct AppTheme: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String

    struct UI: Codable, Equatable {
        var window: String, surface: String, raised: String
        var border: String, hairline: String
        var text: String, muted: String, faint: String
        var accent: String, success: String, warning: String, danger: String, broadcast: String
    }

    struct Terminal: Codable, Equatable {
        var background: String, foreground: String, cursor: String, selection: String
        /// 16 ANSI colours: black, red, green, yellow, blue, magenta, cyan, white, then the bright ones.
        var ansi: [String]
    }

    struct Mascot: Codable, Equatable {
        var body: String, eyes: String
    }

    var ui: UI
    var terminal: Terminal
    var mascot: Mascot
}

extension Notification.Name {
    static let crossAgentThemeChanged = Notification.Name("dev.crossagent.themeChanged")
}
