import AppKit

/// `Input type="password"`: the Input frame around AppKit's secure text field, so typed text never
/// sits in a plain text view (no undo history, no services, no spelling). Default size only.
public final class SecureInputView: DSView, NSTextFieldDelegate {
    private let decoration = BoxDecorationLayer()
    private let field = Field()
    private var state = FieldView.State() { didSet { if state != oldValue { restyle() } } }

    public var text: String {
        get { active.stringValue }
        set { field.stringValue = newValue; if revealed { plainField?.stringValue = newValue } }
    }
    public var placeholder: String = "" { didSet { applyPlaceholder() } }
    public var isEnabled: Bool {
        get { state.enabled }
        set {
            state.enabled = newValue; field.isEnabled = newValue; plainField?.isEnabled = newValue
            eye?.isEnabled = newValue; alphaValue = newValue ? 1 : 0.64
        }
    }

    /// `SecretRequestField`'s show/hide eye (SecretRequestCard.tsx:331-372 at 5258, #31257): an `icon-xs` ghost button
    /// with a 16pt eye at the input group's inline end. Showing swaps in a plain field with the same text; the toggle
    /// keeps focus and the selection where they were (#42309). `revealLabel` is its "Show {label}".
    public var revealLabel: String? {
        didSet {
            guard revealLabel != nil else { eye?.removeFromSuperview(); eye = nil; setRevealed(false); return }
            if eye == nil {
                let b = ButtonView(nil, icon: .eye, variant: .ghost, size: .iconXs)
                b.iconSize = 16 // `sm:[&_svg]:size-4`: the input group drops the size's `size-3.5`
                b.action = { [weak self] in self?.setRevealed(!(self?.revealed ?? false)) }
                addSubview(b)
                eye = b
            }
            eye?.setAccessibilityLabel(revealLabel)
            needsLayout = true
        }
    }
    public private(set) var revealed = false
    private var eye: ButtonView?
    private var plainField: PlainField?
    private var active: NSTextField { revealed ? plainField ?? field : field }
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
    public override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(active) ?? false }
    public override func mouseDown(with event: NSEvent) { if state.enabled { window?.makeFirstResponder(active) } }

    public func controlTextDidBeginEditing(_ obj: Notification) { state.focused = true }
    public func controlTextDidEndEditing(_ obj: Notification) {
        // The toggle moves focus between the two fields; that is not the user leaving the input.
        guard !swapping else { return }
        state.focused = false; onCommit?(active.stringValue)
    }
    private var swapping = false

    private func setRevealed(_ value: Bool) {
        guard value != revealed else { return }
        if value, plainField == nil {
            let p = PlainField()
            p.isBordered = false
            p.drawsBackground = false
            p.focusRingType = .none
            p.font = field.font
            p.textColor = field.textColor
            p.delegate = self
            p.onFocus = { [weak self] in self?.state.focused = true }
            p.cell?.isScrollable = true
            p.cell?.wraps = false
            p.isEnabled = field.isEnabled
            p.placeholderAttributedString = field.placeholderAttributedString
            addSubview(p)
            plainField = p
        }
        let from = active
        let editor = from.currentEditor()
        let focused = editor != nil && window?.firstResponder === editor
        let selection = editor?.selectedRange
        swapping = true
        revealed = value
        let to = active
        to.stringValue = from.stringValue
        // The plain copy holds the secret only while it shows.
        if !value { plainField?.stringValue = "" }
        from.isHidden = true
        to.isHidden = false
        if focused, window?.makeFirstResponder(to) == true, let selection { to.currentEditor()?.selectedRange = selection }
        swapping = false
        eye?.icon = value ? .eyeOff : .eye
        needsLayout = true
    }
    /// DraftInput: the value when focus leaves or on Return.
    public var onCommit: (@MainActor (String) -> Void)?
    /// Inline padding: 12 for the default size, 9 for `size="sm"` (T3 `px-[calc(--spacing(2.5)-1px)]` plus the border).
    public var inset: CGFloat = 12 { didSet { needsLayout = true } }
    /// `font="mono"`.
    public var monospaced = false { didSet { field.font = monospaced ? DSFont.mono(14) : DSFont.ui(14); applyPlaceholder() } }
    /// Each edit (a Save button follows the draft).
    public var onChange: (@MainActor (String) -> Void)?
    public func controlTextDidChange(_ obj: Notification) { onChange?(active.stringValue) }

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
        plainField?.font = field.font
        plainField?.placeholderAttributedString = field.placeholderAttributedString
    }

    private func restyle() {
        decoration.boxStyle = FieldStyles.frame(state: state, radius: DesignGeometry.radius(10, in: self))
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        field.textColor = Themed.color(\.contrastForeground)
        plainField?.textColor = field.textColor
        applyPlaceholder()
        decoration.setNeedsDisplay()
        restyle()
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let h = ceil(field.intrinsicContentSize.height)
        // With the eye: the input's `pe-2`, then the addon, whose button ends 4pt in (`pe-[11px]` less `-me-2`, plus the border).
        var trailing = inset
        if let eye {
            eye.frame = NSRect(x: bounds.width - 4 - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
            trailing = 4 + 24 + 8
        }
        let frame = NSRect(x: inset, y: (bounds.height - h) / 2, width: max(0, bounds.width - inset - trailing), height: h)
        field.frame = frame
        plainField?.frame = frame
    }

    /// The shown secret's field, which reports focus like `Field`.
    final class PlainField: NSTextField {
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?() }
            return ok
        }
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
