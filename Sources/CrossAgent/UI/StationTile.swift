import AppKit
import SwiftTerm
import SwiftUI

/// What a station tile shows: a tmux session, or a window pane whose process ended.
enum StationItem: Identifiable {
    case session(TmuxSessionInfo)
    case exitedPane(PaneSession)

    var id: String {
        switch self {
        case .session(let s): return s.id
        case .exitedPane(let p): return "pane/\(p.id.uuidString)"
        }
    }

    var hostId: String {
        switch self {
        case .session(let s): return s.hostId
        case .exitedPane(let p): return p.host.id
        }
    }

    var name: String {
        switch self {
        case .session(let s): return s.name
        case .exitedPane(let p): return p.session
        }
    }

    var status: SessionStatus {
        switch self {
        case .session(let s): return s.status
        case .exitedPane: return .exited
        }
    }
}

struct StationTile: View {
    var item: StationItem
    var host: Host?
    var selected: Bool
    var hovered: Bool

    private var accent: SwiftUI.Color { host.map(Palette.accent) ?? Palette.muted }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(6)
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: Palette.radius, style: .continuous).fill(Palette.pane))
        .clipShape(RoundedRectangle(cornerRadius: Palette.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Palette.radius, style: .continuous)
                .strokeBorder(selected || hovered ? accent.opacity(selected ? 0.9 : 0.6) : Palette.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Palette.radius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Dot(color: accent, size: 7)
            Text(host?.name ?? item.hostId)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            Text(item.name)
                .foregroundStyle(Palette.text)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if case .session(let s) = item, s.isClaude {
                Text("claude").foregroundStyle(Palette.faint)
            }
            Spacer(minLength: 6)
            StatusPill(status: item.status)
            duration
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: Palette.headerHeight)
    }

    @ViewBuilder private var duration: some View {
        let since: Date? = {
            switch item {
            case .session(let s): return s.createdAt
            case .exitedPane(let p): return p.startedAt
            }
        }()
        if let since, item.status != .exited {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.format(ctx.date.timeIntervalSince(since)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch item {
        case .session(let s) where !s.capture.isEmpty:
            TerminalPreview(capture: s.capture, cols: s.cols, rows: s.rows)
                .opacity(s.status == .exited ? 0.5 : 1)
        case .session:
            placeholder("waiting for first capture")
        case .exitedPane:
            placeholder("Session ended. Click to open the pane and reconnect.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.faint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 12s, 4m, 1h 12m, 2d 3h
    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

struct StatusPill: View {
    var status: SessionStatus

    static func color(_ s: SessionStatus) -> SwiftUI.Color {
        switch s {
        case .running: return SwiftUI.Color(nsColor: NSColor(hex: "#5fd39a"))
        case .idle: return Palette.muted
        case .waitingForInput: return Palette.connecting
        case .exited: return Palette.danger.opacity(0.75)
        }
    }

    static func label(_ s: SessionStatus) -> String {
        switch s {
        case .running: return "running"
        case .idle: return "idle"
        case .waitingForInput: return "needs input"
        case .exited: return "exited"
        }
    }

    var body: some View {
        let c = Self.color(status)
        HStack(spacing: 5) {
            if status == .running { PulsingDot(color: c) } else { Dot(color: c, size: 6) }
            Text(Self.label(status))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(c)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(c.opacity(0.12)))
    }
}

/// Pulses on the render server (Core Animation), so the app itself stays idle.
/// A SwiftUI repeatForever animation re-rendered the station every frame.
struct PulsingDot: NSViewRepresentable {
    var color: SwiftUI.Color

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        v.wantsLayer = true
        let dot = CALayer()
        dot.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
        dot.cornerRadius = 3
        v.layer?.addSublayer(dot)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        v.layer?.sublayers?.first?.backgroundColor = NSColor(color).cgColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: 6, height: 6)
    }
}

// MARK: - Live preview

/// Read only SwiftTerm view that renders a `capture-pane -e` screen, scaled so the
/// session's cols x rows fill the space.
struct TerminalPreview: NSViewRepresentable {
    var capture: String
    var cols: Int
    var rows: Int

    func makeNSView(context: Context) -> PreviewContainer { PreviewContainer() }

    func updateNSView(_ view: PreviewContainer, context: Context) {
        view.update(capture: capture, cols: cols, rows: rows)
    }
}

final class PreviewContainer: NSView {
    private let term = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    private var cols = 80
    private var rows = 24
    private var capture = ""
    private var fed: String?
    private var fontSize: CGFloat = 0
    private var fittedFor: (CGSize, Int, Int)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        Theme.apply(to: term)
        term.allowMouseReporting = false
        term.changeScrollback(0)
        addSubview(term)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Clicks go to the SwiftUI tile, never to the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(capture: String, cols: Int, rows: Int) {
        let c = min(max(cols, 10), 400), r = min(max(rows, 4), 200)
        self.capture = capture
        if c != self.cols || r != self.rows {
            self.cols = c
            self.rows = r
            needsLayout = true
        } else {
            feedIfChanged()
        }
    }

    override func layout() {
        super.layout()
        fit()
        feedIfChanged()
    }

    private func fit() {
        let size = bounds.size
        guard size.width > 20, size.height > 20 else { return }
        if let f = fittedFor, f.0 == size, f.1 == cols, f.2 == rows { return }
        fittedFor = (size, cols, rows)

        let base = Self.cell(at: 10)
        let scale = min(size.width / (CGFloat(cols) * base.width), size.height / (CGFloat(rows) * base.height))
        var pt = max(3, min(13, floor(scale * 10 * 4) / 4))
        var frame: NSRect
        // SwiftTerm snaps cells to the pixel grid, so step down until the grid really fits.
        repeat {
            if pt != fontSize {
                fontSize = pt
                term.font = Self.font(pt)
            }
            term.resize(cols: cols, rows: rows)
            frame = term.getOptimalFrameSize()
            pt -= 0.25
        } while (frame.width > size.width || frame.height > size.height) && pt >= 3
        frame.size.width += 0.5
        frame.size.height += 0.5
        frame.origin = CGPoint(x: max(0, floor((size.width - frame.width) / 2)), y: 0)
        if term.frame != frame { term.frame = frame }
        // Setting the frame lets SwiftTerm recompute the grid; pin it back to the pane size.
        term.resize(cols: cols, rows: rows)
        fed = nil
    }

    private func feedIfChanged() {
        guard fittedFor != nil, fed != capture else { return }
        fed = capture
        let lines = capture.split(separator: "\n", omittingEmptySubsequences: false).prefix(rows)
        term.feed(text: "\u{1b}[0m\u{1b}[?25l\u{1b}[H\u{1b}[2J" + lines.joined(separator: "\r\n") + "\u{1b}[0m")
    }

    private static func font(_ size: CGFloat) -> NSFont {
        NSFont(descriptor: Theme.font.fontDescriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static var cellCache: CGSize?

    /// Cell size at `size` points, measured like SwiftTerm does (W advance, ascent + descent + leading).
    private static func cell(at size: CGFloat) -> CGSize {
        if let c = cellCache { return c }
        let f = font(size)
        let w = ("W" as NSString).size(withAttributes: [.font: f]).width
        let h = ceil(f.ascender - f.descender + f.leading)
        let c = CGSize(width: max(w, 1), height: max(h, 1))
        cellCache = c
        return c
    }
}
