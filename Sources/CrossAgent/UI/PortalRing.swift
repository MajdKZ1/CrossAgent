import AppKit
import SwiftUI

/// The Crossover Portal glyph: a ring linking two machine dots, `● ─ ◯ ─ ●`.
/// Drawn with Core Animation layers. Only `.crossing` animates, and that pulse runs in
/// the render server, so the app does no work per frame. Every other state is static.
///
///     PortalRing(state: .steady, size: 14, leading: Palette.accent(mac), trailing: Palette.accent(pc))
///
/// `size` is the ring's diameter. The glyph is `size` tall and `PortalRing.width(for:)`
/// wide (about 3.2 x size with dots, just `size` without). Pass nil for both dot colors to
/// get the ring alone.
struct PortalRing: View {
    enum State: Equatable {
        /// Nothing linked: dim ring and dots.
        case off
        /// Linked and quiet.
        case steady
        /// Something is moving through: the ring pulses softly.
        case crossing
        /// Catching up: amber.
        case syncing
        /// Needs a look: red.
        case conflict
    }

    var state: State
    var size: CGFloat = 14
    var leading: Color?
    var trailing: Color?

    static func width(for size: CGFloat, dots: Bool = true) -> CGFloat { dots ? (size * 3.2).rounded() : size }

    var body: some View {
        let dots = leading != nil || trailing != nil
        // Colors are read here, so a theme switch re-renders and updateNSView re-colours.
        PortalRingLayers(look: PortalRingLayers.Look(
            ring: NSColor(ringColor), leading: leading.map(NSColor.init), trailing: trailing.map(NSColor.init),
            link: NSColor(Palette.border), dim: state == .off, pulse: state == .crossing))
            .frame(width: Self.width(for: size, dots: dots), height: size)
            .accessibilityElement()
            .accessibilityLabel("Crossover Portal, \(label)")
    }

    private var ringColor: Color {
        switch state {
        case .off: Palette.faint
        case .steady, .crossing: Palette.primary
        case .syncing: Palette.warning
        case .conflict: Palette.danger
        }
    }

    private var label: String {
        switch state {
        case .off: "off"
        case .steady: "linked"
        case .crossing: "crossing"
        case .syncing: "catching up"
        case .conflict: "conflict"
        }
    }
}

private struct PortalRingLayers: NSViewRepresentable {
    struct Look: Equatable {
        var ring: NSColor
        var leading: NSColor?
        var trailing: NSColor?
        var link: NSColor
        var dim: Bool
        var pulse: Bool
    }

    var look: Look

    func makeNSView(context: Context) -> PortalRingView { PortalRingView() }

    func updateNSView(_ view: PortalRingView, context: Context) { view.look = look }
}

final class PortalRingView: NSView {
    fileprivate var look: PortalRingLayers.Look? {
        didSet { if look != oldValue { apply() } }
    }

    private let ring = CAShapeLayer()
    private let core = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let leftLink = CALayer(), rightLink = CALayer()
    private let leftDot = CALayer(), rightDot = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [leftLink, rightLink, halo, core, ring, leftDot, rightDot] as [CALayer] { layer?.addSublayer(l) }
        ring.fillColor = nil
        halo.fillColor = nil
        halo.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Never takes clicks, so it can sit on top of a button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height, w = bounds.width
        let lineWidth = max(1.25, h * 0.12)
        let ringRect = CGRect(x: (w - h) / 2, y: 0, width: h, height: h).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        for l in [ring, halo, core] {
            l.frame = bounds
        }
        ring.path = CGPath(ellipseIn: ringRect, transform: nil)
        ring.lineWidth = lineWidth
        core.path = CGPath(ellipseIn: ringRect.insetBy(dx: h * 0.22, dy: h * 0.22), transform: nil)
        // The halo scales around the ring's centre.
        halo.frame = CGRect(x: (w - h) / 2, y: 0, width: h, height: h)
        halo.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: h, height: h).insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        halo.lineWidth = lineWidth

        let dot = max(3, (h * 0.36).rounded())
        let link = max(1, (h * 0.08).rounded())
        let showDots = look?.leading != nil || look?.trailing != nil
        leftDot.frame = CGRect(x: 0, y: (h - dot) / 2, width: dot, height: dot)
        rightDot.frame = CGRect(x: w - dot, y: (h - dot) / 2, width: dot, height: dot)
        leftDot.cornerRadius = dot / 2
        rightDot.cornerRadius = dot / 2
        leftLink.frame = CGRect(x: dot, y: (h - link) / 2, width: max(0, ringRect.minX - dot), height: link)
        rightLink.frame = CGRect(x: ringRect.maxX, y: (h - link) / 2, width: max(0, w - dot - ringRect.maxX), height: link)
        for l in [leftDot, rightDot, leftLink, rightLink] { l.isHidden = !showDots }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped when a layer leaves the window, so put the pulse back.
        updatePulse()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [ring, core, halo, leftLink, rightLink, leftDot, rightDot] { l.contentsScale = scale }
    }

    private func apply() {
        guard let look else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let alpha: CGFloat = look.dim ? 0.45 : 1
        ring.strokeColor = look.ring.withAlphaComponent(look.ring.alphaComponent * alpha).cgColor
        halo.strokeColor = look.ring.cgColor
        core.fillColor = look.ring.withAlphaComponent(look.dim ? 0.08 : 0.22).cgColor
        leftDot.backgroundColor = look.leading?.withAlphaComponent(alpha).cgColor
        rightDot.backgroundColor = look.trailing?.withAlphaComponent(alpha).cgColor
        leftLink.backgroundColor = look.link.cgColor
        rightLink.backgroundColor = look.link.cgColor
        CATransaction.commit()
        needsLayout = true
        updatePulse()
    }

    private func updatePulse() {
        let on = look?.pulse == true && window != nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if on, !reduce {
            guard halo.animation(forKey: "pulse") == nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 1.7
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.6
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.repeatCount = .infinity
            halo.add(group, forKey: "pulse")
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.55
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            core.add(breathe, forKey: "pulse")
        } else {
            halo.removeAllAnimations()
            core.removeAllAnimations()
            // Reduce Motion: a still halo says "crossing" without moving.
            halo.transform = on && reduce ? CATransform3DMakeScale(1.4, 1.4, 1) : CATransform3DIdentity
            halo.opacity = on && reduce ? 0.35 : 0
        }
    }
}
