import AppKit
import QuartzCore

/// T3's `Collapsible` panel (`apps/web/src/components/ui/collapsible.tsx`): clips its content and
/// opens or closes over 200ms `cubic-bezier(.4,0,.2,1)`, instantly with Reduce Motion or `animates = false`.
/// Spec: ui-components-b.md section 16. The trigger is any control that flips `isOpen`.
/// The height change is a mask animation on the GPU; the reported height switches once.
/// ponytail: siblings below jump at the start of opening and the end of closing instead of sliding;
/// animate the owner's layout too if a screen stacks content under a collapsible
public final class CollapsibleView: DSView {
    public let content: NSView
    public var animates = true
    public var isOpen: Bool { didSet { if isOpen != oldValue { transition() } } }
    /// Called when the reported height changes, so the owner can lay out again.
    public final var onHeightChange: (@MainActor () -> Void)?

    private var reportsOpen: Bool
    private let mask = CALayer()

    public init(content: NSView, isOpen: Bool = false) {
        self.content = content
        self.isOpen = isOpen
        reportsOpen = isOpen
        super.init(frame: .zero)
        addSubview(content)
        mask.backgroundColor = CGColor(gray: 0, alpha: 1)
        mask.anchorPoint = .zero
        mask.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.mask = mask
    }

    private var contentHeight: CGFloat {
        let h = content.intrinsicContentSize.height
        return h == NSView.noIntrinsicMetric ? content.fittingSize.height : h
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: reportsOpen ? contentHeight : 0)
    }

    public override func layout() {
        super.layout()
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        if mask.animation(forKey: "bounds.size.height") == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: isOpen ? contentHeight : 0)
            CATransaction.commit()
        }
    }

    private func transition() {
        let target = isOpen ? contentHeight : 0
        if isOpen { setReportsOpen(true) }
        guard animates, !Motion.reduced, window != nil else {
            mask.removeAllAnimations()
            setReportsOpen(isOpen)
            needsLayout = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.setReportsOpen(false)
            }
        }
        Motion.animate(mask, keyPath: "bounds.size.height", to: target, duration: 0.2)
        mask.bounds.size.height = target
        CATransaction.commit()
    }

    private func setReportsOpen(_ open: Bool) {
        guard reportsOpen != open else { return }
        reportsOpen = open
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }
}

/// T3's `CollapsibleSectionHeader` (`collapsible-section-header.tsx`): a full-width 32px button with
/// a label, a 1px rule that fills the row, an optional accessory and a chevron that turns 180 degrees
/// over 150ms when expanded. Spec: ui-components-b.md section 17.
public final class CollapsibleSectionHeaderView: ControlView {
    public enum Tone: String, CaseIterable, Sendable { case muted, info, emphasized, accent }

    public var tone: Tone = .muted { didSet { restyle() } }
    public var title: String { didSet { label.text = title; needsLayout = true } }
    public var isExpanded = false {
        didSet { if isExpanded != oldValue { rotateChevron(animated: true); setAccessibilityExpanded(isExpanded) } }
    }
    public var accessory: NSView? {
        didSet { oldValue?.removeFromSuperview(); accessory.map(addSubview); needsLayout = true }
    }
    public final var onToggle: (@MainActor (Bool) -> Void)?

    private let decoration = BoxDecorationLayer()
    private let label = LabelView()
    private let rule = CALayer()
    private let chevron = CAShapeLayer()

    public init(_ title: String, tone: Tone = .muted, expanded: Bool = false) {
        self.title = title
        super.init(frame: .zero)
        scalesWhenPressed = false
        self.tone = tone
        isExpanded = expanded
        label.text = title
        label.font = DSFont.ui(12, weight: .medium)
        label.lineHeight = 16
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.addSublayer(rule)
        layer?.addSublayer(chevron)
        addSubview(label)
        rule.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        chevron.actions = ["position": NSNull(), "bounds": NSNull(), "strokeColor": NSNull(), "transform": NSNull(), "path": NSNull()]
        chevron.fillColor = nil
        chevron.lineWidth = 1 // stroke 2 of 24 units at 12px
        chevron.lineCap = .round
        chevron.lineJoin = .round
        // `m6 9 6 6 6-6` in a 12px box.
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 3, y: 4.5), CGPoint(x: 6, y: 7.5), CGPoint(x: 9, y: 4.5)])
        chevron.path = p
        chevron.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        rotateChevron(animated: false)
        setAccessibilityExpanded(expanded)
        restyle()
    }

    public override func performAction() {
        isExpanded.toggle()
        onToggle?(isExpanded)
        super.performAction()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let midY = bounds.height / 2
        var x: CGFloat = 8
        var right = bounds.width - 8 - 12
        if let accessory {
            let s = accessory.intrinsicContentSize
            accessory.frame = NSRect(x: right - 8 - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
            right -= 8 + s.width
        }
        // T3 3814 ThreadRelationshipsControl.tsx:144-150 protects counts and truncates the label.
        let labelWidth = min(label.textWidth, max(0, right - 8 - x - 8))
        label.frame = NSRect(x: x, y: midY - 8, width: labelWidth, height: 16)
        x += labelWidth + 8
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rule.isHidden = accessory != nil && !DesignGeometry.usesClassic(self)
        rule.frame = CGRect(x: x, y: midY - 0.5, width: max(0, right - 8 - x), height: 1)
        chevron.position = CGPoint(x: bounds.width - 8 - 6, y: midY)
        CATransaction.commit()
    }

    private func rotateChevron(animated: Bool) {
        let angle: CGFloat = DesignGeometry.usesClassic(self) ? (isExpanded ? .pi : 0) : (isExpanded ? 0 : -.pi / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, window != nil, !Motion.reduced {
            Motion.animate(chevron, keyPath: "transform.rotation.z", to: angle, duration: Motion.Durations.default)
        }
        chevron.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func updateLayer() { restyle() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        rotateChevron(animated: false)
        restyle()
    }

    private func restyle() {
        let text: NSColor, line: NSColor
        switch tone {
        case .muted:
            text = Themed.color(\.contrastSidebarMutedForeground, DesignGeometry.usesClassic(self) ? 0.6 : 1)
            line = Themed.color(\.contrastSidebarBorder, DesignGeometry.usesClassic(self) ? 0.6 : 0.5)
        case .info:
            let b4 = Tokens.baseColors["blue-400"]!
            text = DesignGeometry.usesClassic(self) ? Themed.color(light: Tokens.baseColors["blue-600"]!, 1, dark: b4, 1) : Themed.color(\.contrastSidebarMutedForeground)
            line = DesignGeometry.usesClassic(self) ? Themed.color(light: Tokens.baseColors["blue-500"]!, 0.2, dark: b4, 0.15) : Themed.color(\.contrastSidebarBorder, 0.5)
        case .emphasized:
            text = Themed.color(\.contrastSidebarForeground, 0.8)
            line = Themed.color(\.contrastSidebarForeground, 0.25)
        case .accent:
            text = Themed.color(\.primary)
            line = Themed.color(\.primary, 0.5)
        }
        label.color = text
        var box = BoxStyle()
        box.radius = DesignGeometry.radius(8, in: self)
        // `ring-inset` is in the class list, but Chromium paints this ring outside the box with T3's
        // compiled CSS (fidelity 18.9% inset vs 1.7% outside), so we copy the render, not the class name.
        if state.focusVisible { box.shadows = [BoxShadow(spread: 2, color: Themed.color(\.ring, 0.7))] }
        decoration.boxStyle = box
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rule.backgroundColor = line.cgColor(in: self)
        chevron.strokeColor = text.cgColor(in: self)
        CATransaction.commit()
    }
}
