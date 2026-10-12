import AppKit
import QuartzCore

/// T3's `Checkbox` (`checkbox.tsx`) and `Radio` (`radio-group.tsx`), desktop values: a 16px box
/// with radius 4 (checkbox) or a circle (radio). They share every rule except the shape and the mark.
/// Spec: docs/research/recovered/ui-components-b.md sections 4 and 5. No animation besides
/// T3's 150ms box-shadow transition, which we skip: the indicator itself appears instantly.
public class ChoiceView: ControlView {
    public enum Value: Sendable { case off, on, mixed }

    public var value: Value = .off { didSet { if value != oldValue { restyle(); setAccessibilityValue(value == .on ? 1 : value == .mixed ? 2 : 0) } } }
    /// `aria-invalid`: destructive border, no shadows, destructive focus ring.
    public var isInvalid = false { didSet { restyle() } }
    public final var onChange: (@MainActor (Value) -> Void)?

    let round: Bool
    private let decoration = BoxDecorationLayer()
    private let mark = CAShapeLayer()

    init(round: Bool) {
        self.round = round
        super.init(frame: .zero)
        scalesWhenPressed = false
        decoration.host = self
        decoration.transition = [.shadow] // transition-shadow (checkbox.tsx:11, radio-group.tsx:22)
        layer?.addSublayer(decoration)
        layer?.addSublayer(mark)
        layer?.masksToBounds = false
        mark.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "hidden": NSNull(),
                        "position": NSNull(), "bounds": NSNull()]
        mark.lineCap = .round
        mark.lineJoin = .round
        restyle()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) } // `sm:size-4`

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.frame = bounds
        mark.path = markPath()
        CATransaction.commit()
    }

    /// Checkbox: the lucide-style check or dash in a 12px box (`sm:size-3`), stroke 3 of 24 units.
    /// Radio: the 6px dot (`sm:before:size-1.5`). Coordinates are top-left, like the flipped host.
    private func markPath() -> CGPath {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if round { return CGPath(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6), transform: nil) }
        let s: CGFloat = 12 / 24
        let t = CGAffineTransform(translationX: c.x - 6, y: c.y - 6).scaledBy(x: s, y: s)
        let p = CGMutablePath()
        if value == .mixed {
            p.move(to: CGPoint(x: 5.252, y: 12), transform: t)
            p.addLine(to: CGPoint(x: 18.748, y: 12), transform: t)
        } else {
            p.addLines(between: [CGPoint(x: 5.252, y: 12.7), CGPoint(x: 10.2, y: 18.63), CGPoint(x: 18.748, y: 5.37)], transform: t)
        }
        return p
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func updateLayer() { restyle() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }

    func restyle() {
        var box = BoxStyle()
        box.radius = round ? 9999 : 4
        let checked = value == .on
        if checked {
            // The indicator (`-inset-px`, bg-primary) covers the whole border box.
            box.fill = Themed.color(\.primary)
        } else {
            box.border = isInvalid
                ? Themed.color(\.destructive, state.focusVisible ? 0.64 : 0.36)
                : Themed.color(\.contrastInput)
            box.fill = Themed.color(light: \.background, 1, dark: \.contrastInput, 0.32)
            box.backgroundClip = .paddingInLight
            if state.enabled && !isInvalid {
                box.shadows.append(BoxShadow(y: 1, blur: 2, color: Themed.black(0.05)))
                box.beforeShadows.append(BoxShadow(y: 1, color: Themed.pick(light: Themed.black(0.04), dark: .clear)))
                box.beforeShadows.append(BoxShadow(y: -1, color: Themed.pick(light: .clear, dark: Themed.white(0.06))))
            }
        }
        if state.focusVisible {
            let ring = isInvalid ? Themed.color(light: \.destructive, 0.48, dark: \.destructive, 0.24) : Themed.color(\.ring)
            box.shadows = BoxShadow.focusRing(ring: ring, offset: Themed.color(\.background)) + box.shadows
        }
        decoration.boxStyle = box

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.isHidden = value == .off || (round && value != .on)
        mark.path = markPath()
        if round {
            mark.fillColor = Themed.color(\.primaryForeground).cgColor(in: self)
            mark.strokeColor = nil
        } else {
            mark.fillColor = nil
            mark.lineWidth = 1.5
            mark.strokeColor = (checked ? Themed.color(\.primaryForeground) : Themed.color(\.contrastForeground)).cgColor(in: self)
        }
        CATransaction.commit()
    }
}

public final class CheckboxView: ChoiceView {
    public convenience init(value: Value = .off) {
        self.init(round: false)
        self.value = value
        restyle()
        setAccessibilityRole(.checkBox)
    }

    /// Mixed goes to checked on click, like Base UI.
    public override func performAction() {
        value = value == .on ? .off : .on
        onChange?(value)
        super.performAction()
    }
}

public final class RadioView: ChoiceView {
    public convenience init(checked: Bool = false) {
        self.init(round: true)
        value = checked ? .on : .off
        restyle()
        setAccessibilityRole(.radioButton)
    }

    public var isChecked: Bool {
        get { value == .on }
        set { value = newValue ? .on : .off }
    }

    public override func performAction() {
        guard !isChecked else { return }
        isChecked = true
        onChange?(value)
        super.performAction()
    }
}

/// T3's `RadioGroup`: a vertical stack with a 12px gap (`flex flex-col gap-3`) and single selection.
/// Rows are whatever the caller puts in; each row must contain exactly one of `radios`.
public final class RadioGroupView: DSView {
    public let radios: [RadioView]
    private let rows: [NSView]
    public var selectedIndex: Int? {
        didSet { for (i, r) in radios.enumerated() { r.isChecked = i == selectedIndex } }
    }
    public final var onChange: (@MainActor (Int) -> Void)?

    /// `rows` default to the radios themselves; pass label rows to lay out radio plus text.
    public init(radios: [RadioView], rows: [NSView]? = nil, selected: Int? = nil) {
        self.radios = radios
        self.rows = rows ?? radios
        super.init(frame: .zero)
        self.rows.forEach(addSubview)
        for (i, radio) in radios.enumerated() {
            radio.onChange = { [weak self] _ in
                self?.selectedIndex = i
                self?.onChange?(i)
            }
        }
        selectedIndex = selected
        for (i, r) in radios.enumerated() { r.isChecked = i == selected }
        setAccessibilityRole(.radioGroup)
    }

    public override var intrinsicContentSize: NSSize {
        let sizes = rows.map(\.intrinsicContentSize)
        return NSSize(width: sizes.map(\.width).max() ?? 0,
                      height: sizes.map(\.height).reduce(0, +) + 12 * CGFloat(max(0, rows.count - 1)))
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in rows {
            let size = row.intrinsicContentSize
            row.frame = NSRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height + 12
        }
    }
}
