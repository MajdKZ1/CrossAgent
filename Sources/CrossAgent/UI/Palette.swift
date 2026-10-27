import AppKit
import SwiftUI

/// SwiftUI colors and sizes for the window chrome. Terminal colors live in Theme.
enum Palette {
    static let window = Color(nsColor: Theme.window)
    static let pane = Color(nsColor: Theme.pane)
    static let border = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.05)
    static let text = Color(nsColor: NSColor(hex: "#d7dae0"))
    static let muted = Color(nsColor: NSColor(hex: "#8a909c"))
    static let faint = Color(nsColor: NSColor(hex: "#5b616c"))
    static let connecting = Color(nsColor: NSColor(hex: "#f5b041"))
    static let exited = Color(nsColor: NSColor(hex: "#5b616c"))
    /// Broadcast toggle and the bar across the top while it is on.
    static let broadcast = Color(nsColor: NSColor(hex: "#ff9f6e"))
    /// Sync indicator when every session is synced and watching.
    static let synced = Color(nsColor: NSColor(hex: "#8fd694"))
    /// Primary actions and the drop highlight. Same blue as the Mac accent.
    static let primary = Color(nsColor: NSColor(hex: "#6ea8fe"))
    static let danger = Color(nsColor: NSColor(hex: "#f07178"))
    static let chip = Color.white.opacity(0.04)
    static let chipHover = Color.white.opacity(0.08)

    static let radius: CGFloat = 10
    static let gap: CGFloat = 6
    static let headerHeight: CGFloat = 28
    static let topBarHeight: CGFloat = 38
    /// Room for the traffic lights, which sit over the top bar.
    static let trafficLightInset: CGFloat = 78

    static func accent(_ host: Host) -> Color { Color(nsColor: NSColor(hex: host.accent)) }
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
