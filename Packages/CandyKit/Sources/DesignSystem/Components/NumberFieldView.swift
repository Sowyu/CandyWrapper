import AppKit

/// T3's `NumberField` (`apps/web/src/components/ui/number-field.tsx`): Input's frame around a minus
/// stepper, a centered tabular-digit input and a plus stepper. `:focus-within` shows the ring, so a
/// stepper click shows it too. Spec: docs/research/recovered/ui-components-a.md section 6.
public final class NumberFieldView: BoxView {
    public enum Size: String, CaseIterable, Sendable {
        case sm, `default`, lg
        /// Group height with border, stepper inline padding.
        var metrics: (height: CGFloat, padding: CGFloat) {
            switch self {
            case .sm: (28, 9)
            case .default: (32, 11)
            case .lg: (36, 11)
            }
        }
    }

    public var value: Double { didSet { if value != oldValue { syncText() } } }
    public var step: Double = 1
    public var range: ClosedRange<Double> = -.infinity ... .infinity
    public final var onChange: (@MainActor (Double) -> Void)?
    public let size: Size
    public var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.64; input.isEnabled = isEnabled; restyle() } }

    let input = InputView(placeholder: "", text: "", size: .default)
    /// The typed text, before Return or blur commits it (empty while the field is cleared).
    public var text: String { input.text }
    let decrement = NumberStepperView(icon: .minus)
    let increment = NumberStepperView(icon: .plus)
    private var focused = false

    public init(value: Double, size: Size = .default) {
        self.value = value
        self.size = size
        super.init(frame: .zero)
        decoration.transition = [.shadow, .border] // transition-shadow (number-field.tsx:36)
        input.unstyled = true
        input.font = DSFont.ui(14).monospacedDigits
        input.lineHeight = size.metrics.height - 2
        input.onStateChange = { [weak self] s in self?.setFocused(s.focused) }
        input.onCommit = { [weak self] text in self?.commit(text) }
        input.onChange = { [weak self] _ in self?.needsLayout = true }
        decrement.action = { [weak self] in self?.stepBy(-1) }
        increment.action = { [weak self] in self?.stepBy(1) }
        decrement.corners = .leading
        increment.corners = .trailing
        [decrement, input, increment].forEach(addSubview)
        syncText()
        restyle()
    }

    /// Forces focus for the gallery and visual tests.
    public func previewFocus(_ on: Bool) { setFocused(on) }

    private func setFocused(_ on: Bool) {
        guard on != focused else { return }
        focused = on
        restyle()
    }

    private func syncText() {
        input.text = value.rounded() == value ? String(Int(value)) : String(value)
        needsLayout = true
    }

    private func commit(_ text: String) {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else { syncText(); return }
        value = min(max(v, range.lowerBound), range.upperBound)
        onChange?(value)
    }

    private func stepBy(_ direction: Double) {
        value = min(max(value + direction * step, range.lowerBound), range.upperBound)
        onChange?(value)
    }

    private func restyle() {
        var state = FieldView.State()
        state.focused = focused
        state.enabled = isEnabled
        var box = FieldStyles.frame(state: state, radius: DesignGeometry.radius(10, in: self))
        if !isEnabled { box.shadows = [] }
        boxStyle = box
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: size.metrics.height) }

    public override func layout() {
        super.layout()
        let p = size.metrics.padding, h = bounds.height - 2
        let stepper = 2 * p + 16
        decrement.frame = NSRect(x: 1, y: 1, width: stepper, height: h)
        increment.frame = NSRect(x: bounds.width - 1 - stepper, y: 1, width: stepper, height: h)
        input.frame = NSRect(x: 1 + stepper, y: 1, width: max(0, bounds.width - 2 - 2 * stepper), height: h)
        // `text-center`: the field editor scrolls horizontally, so center by padding the text's start.
        let textWidth = TextLine(NSAttributedString(string: input.text, attributes: [.font: input.font])).width
        let inset = max(p, (input.frame.width - textWidth) / 2)
        input.paddingOverride = (inset, p)
    }
}

/// The minus and plus steppers: full height, hover `bg-accent` with the group's inner corner radius.
final class NumberStepperView: ControlView {
    private let decoration = BoxDecorationLayer()
    private let icon: IconView
    var corners = BoxStyle.Corners.all { didSet { restyle() } }

    init(icon: IconName) {
        self.icon = IconView(name: icon, size: 16, strokeColor: Themed.color(\.contrastForeground))
        super.init(frame: .zero)
        scalesWhenPressed = false
        decoration.host = self
        transitions = .colors // number-field.tsx:52,70
        decoration.outset = 0
        layer?.addSublayer(decoration)
        addSubview(self.icon)
        restyle()
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = DesignGeometry.radius(9, in: self)
        box.corners = corners
        if state.hovered { box.fill = Themed.color(\.accent) }
        decoration.boxStyle = box
    }
}

extension NSFont {
    /// `tabular-nums`.
    public var monospacedDigits: NSFont {
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
