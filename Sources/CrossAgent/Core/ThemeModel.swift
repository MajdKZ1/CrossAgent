import AppKit

// Contract for the theme system. A theme drives the whole app and the terminals.
// Everyone reads colours through `Palette` (SwiftUI) and `Theme` (terminals); the theme
// work makes those follow `ThemeStore.shared.current`. Layer based views (canvas,
// mascot) listen for `.crossAgentThemeChanged` and recolour themselves.
//
// Colours are hex strings: "#rrggbb", or "#rrggbbaa" for translucent ones.

struct AppTheme: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String

    struct UI: Codable, Equatable {
        var window: String, surface: String, raised: String
        var border: String, hairline: String
        var text: String, muted: String, faint: String
        var accent: String, success: String, warning: String, danger: String, broadcast: String
        /// Sync indicator when everything is synced. Falls back to `success`.
        var synced: String?
        /// Resting and hovered fill of small controls. Fall back to a low alpha of `text`.
        var chip: String?, chipHover: String?
    }

    struct Terminal: Codable, Equatable {
        var background: String, foreground: String, cursor: String, selection: String
        /// Text drawn over the selection. Falls back to black.
        var selectionForeground: String?
        /// 16 ANSI colours: black, red, green, yellow, blue, magenta, cyan, white, then the bright ones.
        var ansi: [String]
    }

    struct Mascot: Codable, Equatable {
        var body: String, eyes: String
    }

    var ui: UI
    var terminal: Terminal
    var mascot: Mascot
    /// Optional per host accent overrides, keyed by host id from hosts.json.
    var hosts: [String: String]?
}

extension Notification.Name {
    static let crossAgentThemeChanged = Notification.Name("dev.crossagent.themeChanged")
}
