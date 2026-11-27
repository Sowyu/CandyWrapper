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
        didSet {
            guard isExpanded != oldValue else { return }
            rotateChevron(animated: true)
            setAccessibilityExpanded(isExpanded)
            // Opening stretches the thinning end out to rest; closing reaches past rest and gathers back.
            if window != nil { stripMotion.stretchStart = (DitherStrip.Motion.now(), isExpanded ? DitherStrip.openFrom : DitherStrip.closeFrom); startStripMotion() }
        }
    }
    public var accessory: NSView? {
        didSet { oldValue?.removeFromSuperview(); accessory.map(addSubview); needsLayout = true }
    }
    public final var onToggle: (@MainActor (Bool) -> Void)?
    /// Under Redesign the rule becomes `DitherStrip` in the row's color and the row takes Redesign's hover fill. The
    /// sidebar's section headers opt in; other headers keep the rule.
    public var dithersRule = false { didSet { if dithersRule != oldValue { needsLayout = true; restyle() } } }

    private let decoration = BoxDecorationLayer()
    private let label = LabelView()
    private let rule = CALayer()
    private let chevron = CAShapeLayer()
    private let hoverFill = CALayer()
    /// The strip: filled with the row's color through `stripMask`, so a color or appearance change never re-renders it.
    private let strip = CALayer()
    private let stripMask = CALayer()
    private var stripSpan: DitherStrip.Span?
    private var showsStrip: Bool { dithersRule && ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

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
        layer?.addSublayer(hoverFill)
        layer?.addSublayer(decoration)
        layer?.addSublayer(rule)
        layer?.addSublayer(strip)
        hoverFill.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
        strip.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        stripMask.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        stripMask.anchorPoint = .zero
        stripMask.magnificationFilter = .nearest
        strip.mask = stripMask
        layer?.addSublayer(chevron)
        addSubview(label)
        rule.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        chevron.actions = ["position": NSNull(), "bounds": NSNull(), "strokeColor": NSNull(), "transform": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
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
        // Redesign's shelves start on the "Threads" label's column (`SidebarView.navSection`), 1pt in from the 8 here.
        var x: CGFloat = showsStrip ? 7 : 8
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
        let dithered = showsStrip
        rule.isHidden = dithered || (accessory != nil && !DesignGeometry.usesClassic(self))
        rule.frame = CGRect(x: x, y: midY - 0.5, width: max(0, right - 8 - x), height: 1)
        strip.isHidden = !dithered
        hoverFill.frame = bounds
        hoverFill.cornerRadius = RedesignTokens.Radius.control
        if dithered { layoutStrip(labelEnd: label.frame.maxX, limit: right - 8, midY: midY) }
        chevron.position = CGPoint(x: bounds.width - 8 - 6, y: midY)
        CATransaction.commit()
    }

    /// Centred on the label's x-height line, about 1pt under the row's middle, with its rows on the cell lattice.
    private func layoutStrip(labelEnd: CGFloat, limit: CGFloat, midY: CGFloat) {
        let span = DitherStrip.span(labelEnd: labelEnd, limit: limit)
        let height = CGFloat(DitherStrip.rows) * DitherStrip.cell
        let top = ((midY + 1 - height / 2) / DitherStrip.cell).rounded() * DitherStrip.cell
        stripRest = CGRect(x: span.minX, y: top, width: span.maxX - span.minX, height: height)
        // Rendered only when the columns change: a width change that moves the label or the chevron.
        if span != stripSpan {
            stripSpan = span
            if stripLink == nil { stripMask.contents = DitherStrip.mask(span) }
        }
        placeStrip()
    }

    // MARK: Strip motion

    /// The strip's frame at rest; an animation adds 1pt of headroom above it for the wave's lift.
    private var stripRest: CGRect = .zero
    private var stripMotion = DitherStrip.Motion()
    private var stripLink: CADisplayLink?

    private func placeStrip() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Moving, the strip gains 1pt on top (the view is flipped) for the wave's lift; the frame mask is that tall.
        strip.frame = stripLink == nil ? stripRest
            : CGRect(x: stripRest.minX, y: stripRest.minY - 1, width: stripRest.width, height: stripRest.height + 1)
        stripMask.frame = strip.bounds
        CATransaction.commit()
    }

    /// One wave along the line: the pointer came onto the row, or the section's count changed. A wave already
    /// running carries on rather than restarting.
    public func playStripWave() {
        guard stripMotion.waveStart == nil else { return }
        stripMotion.waveStart = DitherStrip.Motion.now()
        startStripMotion()
    }

    /// Runs the display link while a wave or a stretch is under way; Redesign's strip only, never with Reduce Motion
    /// or off screen.
    private func startStripMotion() {
        guard showsStrip, !Motion.reduced, window?.isVisible == true, !isHiddenOrHasHiddenAncestor, stripSpan != nil else {
            stripMotion = DitherStrip.Motion()
            return
        }
        if stripLink == nil {
            let link = displayLink(target: self, selector: #selector(stripFrame))
            link.add(to: .main, forMode: .common)
            stripLink = link
            placeStrip()
            restyle()
        }
        stripFrame()
    }

    @objc private func stripFrame() {
        guard let span = stripSpan, window?.isVisible == true,
              let f = stripMotion.frame(now: DitherStrip.Motion.now(), stretchDuration: RedesignTokens.Motion.large) else { endStripMotion(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stripMask.contents = DitherStrip.frameMask(span, stretch: f.stretch, wave: f.wave)
        CATransaction.commit()
    }

    /// Back to the resting strip, pixel for pixel: its own mask, frame and fill.
    private func endStripMotion() {
        stripLink?.invalidate()
        stripLink = nil
        stripMotion = DitherStrip.Motion()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let span = stripSpan { stripMask.contents = DitherStrip.mask(span) }
        CATransaction.commit()
        placeStrip()
        restyle()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, stripLink != nil { endStripMotion() }
    }

    private func rotateChevron(animated: Bool) {
        let angle: CGFloat = DesignGeometry.usesClassic(self) ? (isExpanded ? .pi : 0) : (isExpanded ? 0 : -.pi / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, window != nil, !Motion.reduced {
            if showsStrip {
                Motion.animate(chevron, keyPath: "transform.rotation.z", to: angle, duration: RedesignTokens.Motion.standard,
                               timing: RedesignTokens.Motion.curve)
            } else {
                Motion.animate(chevron, keyPath: "transform.rotation.z", to: angle, duration: Motion.Durations.default)
            }
        }
        chevron.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
        // The pointer came onto the row: one wave. Not again until it has left and come back.
        if state.hovered, !old.hovered { playStripWave() }
    }

    public override func updateLayer() { restyle() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        rotateChevron(animated: false)
        restyle()
    }

    private func restyle() {
        var text: NSColor, line: NSColor
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
        // Redesign's sidebar shelves read as the "Threads" label above the list: the sidebar's muted color at full
        // strength from the sidebar palette, which keeps 4.5:1 over Blur, at 400.
        if showsStrip, tone == .muted || tone == .emphasized {
            text = Themed.color(tone == .muted ? \.sidebarMutedForeground : \.sidebarForeground, sidebar: true)
        }
        let font = showsStrip ? DSFont.ui(12) : DSFont.ui(12, weight: .medium)
        if label.font != font { label.font = font; needsLayout = true }
        label.color = text
        let fill = showsStrip ? RedesignTokens.State.fill(state, dark: effectiveAppearance.isDark)?.cgColor(in: self) : nil
        setHoverFill(fill)
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
        // The mock's 0.7 over the label's color.
        let ink = text.cgColor(in: self)
        // At rest the fill is the ink at 0.7; while the strip moves the fill is full and each dot carries the 0.7 itself,
        // so the wave can brighten it.
        strip.backgroundColor = showsStrip ? ink.copy(alpha: ink.alpha * (stripLink == nil ? DitherStrip.restAlpha : 1)) : nil
        chevron.lineWidth = showsStrip ? IconView.ditherStroke : 1
        CATransaction.commit()
    }

    /// Whether Redesign's hover or press fill is showing, for tests.
    var showsFill: Bool { hoverFill.backgroundColor != nil }

    /// Drops a hover or press the pointer no longer backs: the pointer is off this header or under something over it,
    /// the window isn't key, or no button is down. The sidebar's Snoozed header kept its grey fill with the pointer
    /// nowhere near (the user, 2026-11-21); its row calls this whenever it refreshes, moves or its window resigns key.
    public func dropStaleHover() {
        guard state.hovered || state.active else { return }
        var s = state
        if s.active, NSEvent.pressedMouseButtons == 0 { s.active = false }
        if s.hovered {
            let over: Bool = {
                guard let window, window.isKeyWindow, let content = window.contentView else { return false }
                let point = window.mouseLocationOutsideOfEventStream
                guard bounds.contains(convert(point, from: nil)),
                      let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return false }
                return hit === self || hit.isDescendant(of: self)
            }()
            if !over { s.hovered = false }
        }
        if s != state { previewState(s) }
    }

    /// Redesign's hover: in at once, out over `Motion.fast`.
    private func setHoverFill(_ color: CGColor?) {
        let old = hoverFill.backgroundColor
        guard !CFEqual(old ?? CGColor.clear, color ?? CGColor.clear) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverFill.backgroundColor = color
        CATransaction.commit()
        if color == nil, let old, window != nil, !Motion.reduced {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = old
            fade.toValue = CGColor.clear
            fade.duration = RedesignTokens.Motion.fast
            fade.timingFunction = RedesignTokens.Motion.exitCurve
            hoverFill.add(fade, forKey: "backgroundColor")
        } else {
            hoverFill.removeAnimation(forKey: "backgroundColor")
        }
    }
}
