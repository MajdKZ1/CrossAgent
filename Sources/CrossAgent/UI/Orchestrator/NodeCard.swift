import AppKit
import SwiftUI

/// What a card draws. The stage only hands a card a new root view when this changes,
/// so moving cards around never touches SwiftUI.
struct NodeCardModel: Equatable {
    var node: AgentNode
    var hostLabel: String
    var accent: Color
    var style: NodeStyle
    /// A relay cable is hovering over this card.
    var target: Bool
    /// A relay cable is being dragged out of this card.
    var relaying: Bool
}

/// What a card tells the stage. Locations come from the window, not the gesture, since
/// the card itself moves while it is dragged.
@MainActor
protocol CardEvents: AnyObject {
    func cardTapped(_ id: String)
    func cardAnswer(_ id: String)
    func cardDragChanged(_ id: String)
    func cardDragEnded(_ id: String)
    func handleDragChanged(_ id: String)
    func handleDragEnded(_ id: String)
}

/// Root of a card's hosting view: the card centered in a slightly bigger box, with
/// room for its name, the relay handle and the zzz.
struct CardRoot: View {
    var model: NodeCardModel
    weak var events: CardEvents?
    var orchestrator: Bool
    @State private var hovering = false

    init(model: NodeCardModel, events: CardEvents? = nil, orchestrator: Bool = false) {
        self.model = model
        self.events = events
        self.orchestrator = orchestrator
    }

    static func size(orchestrator: Bool) -> CGSize {
        let card = orchestrator ? OrchMetrics.orchestrator : OrchMetrics.card
        return CGSize(width: card.width + 2 * OrchMetrics.margin.width, height: card.height + 2 * OrchMetrics.margin.height)
    }

    var body: some View {
        let id = model.node.id
        let size = Self.size(orchestrator: orchestrator)
        NodeCard(model: model, onAnswer: { events?.cardAnswer(id) })
            .overlay(alignment: .trailing) {
                if (hovering || model.relaying) && model.style == .live {
                    RelayHandle(accent: model.accent)
                        .offset(x: 9.5)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { _ in events?.handleDragChanged(id) }
                            .onEnded { _ in events?.handleDragEnded(id) })
                }
            }
            .onHover { hovering = $0 }
            .onTapGesture { events?.cardTapped(id) }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in events?.cardDragChanged(id) }
                .onEnded { _ in events?.cardDragEnded(id) })
            .frame(width: size.width, height: size.height)
    }
}

struct NodeCard: View, Equatable {
    var model: NodeCardModel
    var onAnswer: () -> Void

    static func == (a: NodeCard, b: NodeCard) -> Bool { a.model == b.model }

    private var node: AgentNode { model.node }
    private var isOrchestrator: Bool { node.kind == .orchestrator }
    private var size: CGSize { isOrchestrator ? OrchMetrics.orchestrator : OrchMetrics.card }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Palette.radius, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: isOrchestrator ? 7 : 6) {
            HStack(spacing: 6) {
                if isOrchestrator {
                    Text(node.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HostBadge(label: model.hostLabel, accent: model.accent)
                } else {
                    HostBadge(label: model.hostLabel, accent: model.accent)
                    Spacer(minLength: 4)
                    marker
                }
            }
            ActivityLine(node: node, large: isOrchestrator, onAnswer: onAnswer)
        }
        .padding(.horizontal, 11)
        .frame(width: size.width, height: size.height)
        .background(shape.fill(Palette.pane))
        .overlay(shape.strokeBorder(border.0, lineWidth: border.1))
        .overlay {
            if node.state == .thinking && model.style == .live {
                PulseOutline(color: model.accent, radius: Palette.radius)
            }
        }
        .overlay(alignment: .top) {
            if !isOrchestrator {
                Text(node.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(model.style == .live ? Palette.text : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size.width + 60)
                    .offset(y: -OrchMetrics.label)
            }
        }
        .overlay(alignment: .topTrailing) {
            if node.state == .idle && !isOrchestrator {
                SleepZ().frame(width: 18, height: 22).offset(x: 4, y: -24)
            }
        }
        .help(helpText)
    }

    @ViewBuilder private var marker: some View {
        if model.style != .live {
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Palette.synced)
        } else if node.kind == .worker {
            Image(systemName: "terminal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.faint)
                .help("Worker in its own terminal")
        } else {
            Circle().strokeBorder(Palette.faint, lineWidth: 1).frame(width: 6, height: 6)
                .help("Subagent")
        }
    }

    private var border: (Color, CGFloat) {
        if model.target { return (model.accent.opacity(0.95), 1.5) }
        switch node.state {
        case .needsInput: return (Palette.connecting.opacity(0.8), 1.5)
        case .error: return (Palette.danger.opacity(0.85), 1.5)
        case .working where model.style == .live: return (model.accent.opacity(0.4), 1)
        default: return (Palette.border, 1)
        }
    }

    private var helpText: String {
        if case .error(let e) = node.state { return e }
        if let p = node.prompt, !p.isEmpty { return p }
        return node.activity
    }
}

/// "Mac" or "PC" in the host's accent.
struct HostBadge: View {
    var label: String
    var accent: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(accent.opacity(0.13)))
    }

    /// Last word of the host name: "This Mac" is "Mac", "Linux PC" is "PC".
    static func label(_ host: Host?, id: String) -> String {
        guard let host else { return id }
        return host.name.split(separator: " ").last.map(String.init) ?? host.name
    }
}

/// The one line under the badge: what the node is doing, or what it needs.
private struct ActivityLine: View {
    var node: AgentNode
    var large: Bool
    var onAnswer: () -> Void

    var body: some View {
        Group {
            switch node.state {
            case .needsInput(let q):
                HStack(spacing: 6) {
                    Text(q.isEmpty ? "Needs input" : q)
                        .foregroundStyle(Palette.connecting)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button("Answer", action: onAnswer)
                        .buttonStyle(AnswerButtonStyle())
                }
            case .waiting(let names):
                Text(names.isEmpty ? "Waiting" : "Waiting on \(names.joined(separator: ", "))")
                    .foregroundStyle(Palette.faint)
            case .error(let e):
                Text(e.isEmpty ? "Failed" : e).foregroundStyle(Palette.danger.opacity(0.9))
            case .working:
                Text(node.activity).foregroundStyle(Palette.text.opacity(0.85))
            default:
                Text(node.activity).foregroundStyle(Palette.muted)
            }
        }
        .font(.system(size: large ? 11.5 : 11, design: node.state == .working ? .monospaced : .default))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnswerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.connecting)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(Palette.connecting.opacity(configuration.isPressed ? 0.3 : 0.16)))
            .contentShape(Capsule())
    }
}

/// Small dot on a card's edge: drag it onto another node to relay.
struct RelayHandle: View {
    var accent: Color

    var body: some View {
        Circle()
            .fill(Palette.pane)
            .overlay(Circle().strokeBorder(accent.opacity(0.9), lineWidth: 1.5))
            .overlay(Circle().fill(accent).frame(width: 3, height: 3))
            .frame(width: 11, height: 11)
            .padding(4)
            .contentShape(Circle())
            .help("Drag onto another node to relay")
    }
}

// MARK: - Core Animation bits

/// Soft pulsing outline for thinking nodes. Runs on the render server, so it costs the
/// app nothing between frames.
struct PulseOutline: NSViewRepresentable {
    var color: Color
    var radius: CGFloat

    func makeNSView(context: Context) -> PulseOutlineView { PulseOutlineView(radius: radius) }

    func updateNSView(_ v: PulseOutlineView, context: Context) {
        v.color = NSColor(color).cgColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseOutlineView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class PulseOutlineView: NSView {
    private let ring = CAShapeLayer()
    private let radius: CGFloat
    var color: CGColor? {
        didSet { if color != oldValue { ring.strokeColor = color } }
    }

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 1.5
        layer?.addSublayer(ring)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.9
        pulse.toValue = 0.15
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(pulse, forKey: "pulse")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius, cornerHeight: radius,
                           transform: nil)
        CATransaction.commit()
    }
}

/// Three z's drifting up over an idle node.
struct SleepZ: NSViewRepresentable {
    func makeNSView(context: Context) -> SleepZView { SleepZView() }
    func updateNSView(_ v: SleepZView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SleepZView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class SleepZView: NSView {
    private var letters: [CATextLayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let color = NSColor(hex: "#8a909c").cgColor
        for i in 0..<3 {
            let z = CATextLayer()
            z.string = "z"
            z.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            z.fontSize = 8 + CGFloat(i) * 1.5
            z.foregroundColor = color
            z.alignmentMode = .center
            z.opacity = 0
            layer?.addSublayer(z)
            letters.append(z)

            let rise = CABasicAnimation(keyPath: "position.y")
            rise.byValue = 12
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.byValue = 4
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.8, 0.8, 0]
            fade.keyTimes = [0, 0.25, 0.65, 1]
            let group = CAAnimationGroup()
            group.animations = [rise, drift, fade]
            group.duration = 2.7
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.9
            group.fillMode = .backwards
            z.add(group, forKey: "float")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for z in letters { z.contentsScale = scale }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        for z in letters {
            z.contentsScale = scale
            z.frame = CGRect(x: 0, y: 0, width: 12, height: 14)
        }
        CATransaction.commit()
    }
}
