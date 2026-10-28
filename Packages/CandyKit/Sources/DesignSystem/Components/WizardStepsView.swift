import AppKit

/// T3's `WizardSteps` (`apps/web/src/components/ui/wizard.tsx`): equal columns in a 14px-radius strip,
/// numbered discs (done, current, upcoming) and truncating labels. The wizard's popup, header, panel and
/// footer are DialogView parts. Spec: docs/research/recovered/ui-components-b.md section 21.
public final class WizardStepsView: BoxView {
    public let steps: [String]
    public var currentStep: Int { didSet { stepViews.forEach { $0.restyle() } } }
    /// `showSummaries`: a finished step reads "Step: summary".
    public var summaries: [String?] = [] { didSet { stepViews.forEach { $0.restyle() } } }
    public final var onStepChange: (@MainActor (Int) -> Void)?
    public private(set) var stepViews: [WizardStepView] = []

    public init(steps: [String], currentStep: Int = 0) {
        self.steps = steps
        self.currentStep = currentStep
        super.init(frame: .zero)
        var box = BoxStyle()
        box.radius = DesignGeometry.radius(14, in: self)
        box.fill = Themed.pick(light: Tokens.baseColors["zinc-25"]!.nsColor, dark: Themed.white(0.04))
        box.shadows = [BoxShadow(spread: 1, color: Themed.pick(light: Themed.black(0.05), dark: Themed.white(0.05)))]
        boxStyle = box
        stepViews = steps.indices.map { WizardStepView(index: $0, owner: self) }
        stepViews.forEach(addSubview)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Setup progress")
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

    public override func layout() {
        super.layout()
        let n = CGFloat(max(1, steps.count))
        let w = (bounds.width - 8 - 4 * (n - 1)) / n
        for (i, v) in stepViews.enumerated() {
            v.frame = NSRect(x: 4 + CGFloat(i) * (w + 4), y: 4, width: w, height: bounds.height - 8)
        }
    }
}

public final class WizardStepView: ControlView {
    let index: Int
    private unowned let owner: WizardStepsView
    private let decoration = BoxDecorationLayer()
    private let disc = BoxDecorationLayer()
    private let number = LabelView()
    private let check = IconView(name: .check, size: 16)
    private let label = LabelView()

    init(index: Int, owner: WizardStepsView) {
        self.index = index
        self.owner = owner
        super.init(frame: .zero)
        scalesWhenPressed = false
        for d in [decoration, disc] { d.host = self; layer?.addSublayer(d) }
        layer?.masksToBounds = false
        number.text = "\(index + 1)"
        number.font = DSFont.ui(14, weight: .medium)
        number.lineHeight = 20
        number.alignment = .center
        label.text = owner.steps[index]
        label.font = DSFont.ui(14, weight: .medium)
        label.lineHeight = 20
        [number, check, label].forEach(addSubview)
        setAccessibilityLabel("\(owner.steps[index]), step \(index + 1)")
        restyle()
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let discRect = NSRect(x: 10, y: (bounds.height - 20) / 2, width: 20, height: 20)
        disc.frame = discRect.insetBy(dx: -disc.outset, dy: -disc.outset)
        number.frame = discRect
        check.frame = discRect.insetBy(dx: 2, dy: 2)
        label.frame = NSRect(x: 38, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 48), height: 20)
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func performAction() {
        super.performAction()
        owner.onStepChange?(index)
    }

    func restyle() {
        let current = owner.currentStep
        var box = BoxStyle()
        box.radius = DesignGeometry.radius(10, in: self)
        if index == current || (state.hovered && state.enabled) { box.fill = Themed.color(\.card) }
        if index == current {
            box.shadows = [BoxShadow(spread: 1, color: Themed.pick(light: Themed.black(0.05), dark: Themed.white(0.05))),
                           BoxShadow(y: 1, blur: 2, color: Themed.pick(light: Themed.black(0.05), dark: .clear))]
        }
        if state.focusVisible { box.shadows.insert(BoxShadow(spread: 2, color: Themed.color(\.ring)), at: 0) }
        decoration.boxStyle = box

        var d = BoxStyle()
        d.radius = DesignGeometry.radius(10, in: self)
        if index < current {
            d.fill = Themed.color(\.primary)
            d.shadows = [BoxShadow(spread: 1, color: Themed.color(\.primary))]
        } else if index == current {
            d.fill = Themed.color(\.primary, 0.1)
            d.shadows = [BoxShadow(spread: 1, color: Themed.color(\.primary, 0.3))]
        } else {
            d.fill = Themed.pick(light: Themed.color(\.card), dark: Themed.white(0.05))
            d.shadows = [BoxShadow(spread: 1, color: Themed.pick(light: Themed.black(0.1), dark: Themed.white(0.1)))]
        }
        disc.boxStyle = d
        disc.setNeedsDisplay()
        check.isHidden = index >= current
        number.isHidden = index < current
        check.strokeColor = Themed.color(\.primaryForeground)
        number.color = index == current ? Themed.color(\.primary) : Themed.color(\.contrastMutedForeground)
        label.color = index == current ? Themed.color(\.contrastForeground) : Themed.color(\.contrastMutedForeground)
        let summary = index < owner.summaries.count ? owner.summaries[index] : nil
        label.text = owner.steps[index] + (index < current ? summary.map { ": \($0)" } ?? "" : "")
    }
}
