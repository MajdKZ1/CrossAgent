import AppKit
import SwiftUI

/// SwiftUI colors and sizes for the window chrome. Terminal colors live in Theme.
/// Colors follow the current theme. Reading one inside a view body subscribes that
/// view to theme switches (ThemeTokens is @Observable), so nothing else is needed.
enum Palette {
    private static var t: ResolvedTheme { ThemeTokens.shared.resolved }

    static var window: Color { Color(nsColor: t.window) }
    static var pane: Color { Color(nsColor: t.surface) }
    /// One step above `pane`, for popovers and cards.
    static var raised: Color { Color(nsColor: t.raised) }
    static var border: Color { Color(nsColor: t.border) }
    static var hairline: Color { Color(nsColor: t.hairline) }
    static var text: Color { Color(nsColor: t.text) }
    static var muted: Color { Color(nsColor: t.muted) }
    static var faint: Color { Color(nsColor: t.faint) }
    static var connecting: Color { Color(nsColor: t.warning) }
    static var exited: Color { Color(nsColor: t.faint) }
    /// Broadcast toggle and the bar across the top while it is on.
    static var broadcast: Color { Color(nsColor: t.broadcast) }
    /// Sync indicator when every session is synced and watching.
    static var synced: Color { Color(nsColor: t.synced) }
    /// Primary actions and the drop highlight.
    static var primary: Color { Color(nsColor: t.accent) }
    static var danger: Color { Color(nsColor: t.danger) }
    static var success: Color { Color(nsColor: t.success) }
    static var warning: Color { Color(nsColor: t.warning) }
    /// Mascot body and eyes, from the theme.
    static var mascotBody: Color { Color(nsColor: t.mascotBody) }
    static var mascotEyes: Color { Color(nsColor: t.mascotEyes) }
    static var chip: Color { Color(nsColor: t.chip) }
    static var chipHover: Color { Color(nsColor: t.chipHover) }

    static let radius: CGFloat = 10
    static let gap: CGFloat = 6
    static let headerHeight: CGFloat = 28
    static let topBarHeight: CGFloat = 38
    /// Room for the traffic lights, which sit over the top bar.
    static let trafficLightInset: CGFloat = 78

    /// Host accents come from hosts.json unless the theme overrides that host.
    static func accent(_ host: Host) -> Color { Color(nsColor: hostAccent(host)) }
    static func hostAccent(_ host: Host) -> NSColor { t.hosts[host.id] ?? NSColor(hex: host.accent) }
}

/// Small rounded control used across the chrome.
struct ChromeButtonStyle: ButtonStyle {
    var active = false
    var tint: Color = Palette.text

    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? tint : Palette.text.opacity(0.85))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? tint.opacity(0.16) : (hovering ? Palette.chipHover : Palette.chip))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(active ? tint.opacity(0.35) : Palette.border, lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Icon only button for pane headers.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Palette.text : Palette.muted)
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Palette.chipHover : .clear))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Tracks hover for a bit of content.
struct Hover<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

struct Dot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}
