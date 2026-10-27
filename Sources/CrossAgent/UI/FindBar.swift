import AppKit

/// Small find field that sits inside a pane's terminal, top right. Enter goes to the
/// older match, Shift+Enter to the newer one, Esc closes. Cmd+G and Cmd+Shift+G are
/// handled by the terminal's key equivalents.
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    /// true for older (up), false for newer (down).
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        field.placeholderString = "Find"
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11.5)
        field.focusRingType = .none
        field.delegate = self
        field.sendsWholeSearchString = false
        field.translatesAutoresizingMaskIntoConstraints = false

        count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)

        let up = button("chevron.up", "Older match (⏎ or ⌘G)", #selector(older))
        let down = button("chevron.down", "Newer match (⇧⏎ or ⇧⌘G)", #selector(newer))
        let close = button("xmark", "Close (Esc)", #selector(closeTapped))

        let stack = NSStackView(views: [field, count, up, down, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setCustomSpacing(6, after: field)
        stack.setCustomSpacing(4, after: count)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            field.widthAnchor.constraint(equalToConstant: 160),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var countText: String { count.stringValue }

    /// nil hides the counter; (0, 0) reads "No results".
    func setCount(_ summary: (index: Int, total: Int)?) {
        guard let summary else { count.stringValue = ""; return }
        count.stringValue = summary.total == 0 ? "No results" : "\(summary.index)/\(summary.total)"
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .accessoryBarAction
        b.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }

    @objc private func older() { onStep?(true) }
    @objc private func newer() { onStep?(false) }
    @objc private func closeTapped() { onClose?() }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        default:
            return false
        }
        return true
    }
}
