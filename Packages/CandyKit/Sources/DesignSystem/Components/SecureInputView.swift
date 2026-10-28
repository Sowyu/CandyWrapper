import AppKit

/// `Input type="password"`: the Input frame around AppKit's secure text field, so typed text never
/// sits in a plain text view (no undo history, no services, no spelling). Default size only.
public final class SecureInputView: DSView, NSTextFieldDelegate {
    private let decoration = BoxDecorationLayer()
    private let field = Field()
    private var state = FieldView.State() { didSet { if state != oldValue { restyle() } } }

    public var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    public var placeholder: String = "" { didSet { applyPlaceholder() } }
    public var isEnabled: Bool {
        get { state.enabled }
        set { state.enabled = newValue; field.isEnabled = newValue; alphaValue = newValue ? 1 : 0.64 }
    }
    public var isInvalid: Bool {
        get { state.invalid }
        set { state.invalid = newValue }
    }
    /// Return in the field.
    public var onSubmit: (@MainActor () -> Void)?

    public init(placeholder: String = "") {
        super.init(frame: .zero)
        decoration.host = self
        decoration.transition = [.shadow, .border] // transition-shadow (input.tsx:68)
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = DSFont.ui(14)
        field.textColor = Themed.color(\.contrastForeground)
        field.delegate = self
        field.onFocus = { [weak self] in self?.state.focused = true }
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(field)
        self.placeholder = placeholder
        applyPlaceholder()
        restyle()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }
    public override var acceptsFirstResponder: Bool { state.enabled }
    public override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(field) ?? false }
    public override func mouseDown(with event: NSEvent) { if state.enabled { window?.makeFirstResponder(field) } }

    public func controlTextDidBeginEditing(_ obj: Notification) { state.focused = true }
    public func controlTextDidEndEditing(_ obj: Notification) { state.focused = false; onCommit?(field.stringValue) }
    /// DraftInput: the value when focus leaves or on Return.
    public var onCommit: (@MainActor (String) -> Void)?
    /// Inline padding: 12 for the default size, 9 for `size="sm"` (T3 `px-[calc(--spacing(2.5)-1px)]` plus the border).
    public var inset: CGFloat = 12 { didSet { needsLayout = true } }
    /// `font="mono"`.
    public var monospaced = false { didSet { field.font = monospaced ? DSFont.mono(14) : DSFont.ui(14); applyPlaceholder() } }
    /// Each edit (a Save button follows the draft).
    public var onChange: (@MainActor (String) -> Void)?
    public func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        onSubmit?()
        return true
    }

    private func applyPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: field.font ?? DSFont.ui(14),
            .foregroundColor: Themed.color(\.contrastPlaceholder),
        ])
    }

    private func restyle() {
        decoration.boxStyle = FieldStyles.frame(state: state, radius: DesignGeometry.radius(10, in: self))
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        field.textColor = Themed.color(\.contrastForeground)
        applyPlaceholder()
        decoration.setNeedsDisplay()
        restyle()
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let h = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: inset, y: (bounds.height - h) / 2, width: max(0, bounds.width - 2 * inset), height: h)
    }

    /// Focus arrives before the first key, so the field reports it itself.
    final class Field: NSSecureTextField {
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?() }
            return ok
        }
    }
}
