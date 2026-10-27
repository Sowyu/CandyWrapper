import AppKit

/// T3's `Button` (`apps/web/src/components/ui/button.tsx`). Values are the desktop ones
/// (`sm:` breakpoint, since the window is never narrower than 640px).
/// Spec: docs/research/recovered/ui-components-a.md section 2.
public final class ButtonView: ControlView {
    public enum Variant: String, CaseIterable, Sendable {
        case `default`, destructive, destructiveOutline, ghost, ghostMuted, ghostDestructive
        case glass, link, mediaClose, mediaNavigation, outline, overlay, secondary, warningOutline
    }

    public enum Size: String, CaseIterable, Sendable {
        case micro, xs, compact, sm, `default`, lg, xl
        case iconTiny, iconMicro, iconXs, iconSm, icon, iconLg, iconXl

        var isIconOnly: Bool { rawValue.hasPrefix("icon") }

        /// Height (border included), inline padding, gap, radius, font px, line-height, icon px.
        var metrics: (height: CGFloat, padding: CGFloat, gap: CGFloat, radius: CGFloat, font: CGFloat, line: CGFloat, icon: CGFloat) {
            switch self {
            case .micro: (20, 5, 4, 6, 11, 16, 12)
            case .xs: (24, 7, 4, 8, 12, 16, 14)
            case .compact: (28, 7, 4, 8, 14, 20, 16)   // tailwind-merge quirk keeps sm:text-sm
            case .sm: (28, 9, 6, 8, 14, 20, 16)
            case .default: (32, 11, 8, 8, 14, 20, 16)
            case .lg: (36, 13, 8, 8, 14, 20, 16)
            case .xl: (40, 15, 8, 8, 16, 24, 18)
            case .iconTiny: (16, 0, 0, 8, 14, 20, 16)  // quirk: unsized icon renders 16px
            case .iconMicro: (20, 0, 0, 6, 14, 20, 16) // quirk: unsized icon renders 16px
            case .iconXs: (24, 0, 0, 8, 14, 20, 14)
            case .iconSm: (28, 0, 0, 8, 14, 20, 16)
            case .icon: (32, 0, 0, 8, 14, 20, 16)
            case .iconLg: (36, 0, 0, 8, 14, 20, 16)
            case .iconXl: (40, 0, 0, 8, 14, 20, 18)
            }
        }
    }

    public var variant: Variant = .default { didSet { restyle() } }
    public var size: Size = .default { didSet { restyle(); invalidateIntrinsicContentSize() } }
    public var title: String? { didSet { label.text = title ?? ""; syncLabel(); invalidateIntrinsicContentSize() } }
    public var icon: IconName? { didSet { updateIcons() } }
    /// Replaces the leading glyph with a visible-only, Reduce Motion-aware spinner.
    public var showsSpinner = false { didSet { if showsSpinner != oldValue { updateIcons() } } }
    /// A leading glyph outside the generated set (T3's inline SVG components), used when `icon` is nil.
    public var iconDefinition: IconDefinition? { didSet { updateIcons() } }
    public var trailingIcon: IconName? { didSet { updateIcons() } }
    /// `justify-between`: the label at the start, the trailing icon at the end.
    public var justifiesBetween = false { didSet { needsLayout = true } }
    /// An explicit icon class such as `size-3`, which beats the size's default icon size.
    public var iconSize: CGFloat? { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    /// Replaces the variant's icon color, for icons with their own `text-*` class.
    public var iconColor: NSColor? { didSet { restyle() } }
    /// `font-mono` on the label (the keybinding When trigger).
    public var monospaced = false { didSet { restyle(); invalidateIntrinsicContentSize() } }
    /// A view after the label in the content group, such as the count pill on the Pull Requests
    /// page's Filters button. Sized by its intrinsic content size.
    public var accessory: NSView? {
        didSet { oldValue?.removeFromSuperview(); accessory.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true }
    }
    /// Labels the button may switch between, stacked in one `inline-grid` cell with the unused ones
    /// `invisible`: the label slot is as wide as the widest, so swapping labels never moves the edges.
    public var reservedTitles: [String] = [] { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    /// See `LabelView.smoothsFont`: off for buttons on glass (backdrop-filter) surfaces.
    public var smoothsFont: Bool {
        get { label.smoothsFont }
        set { label.smoothsFont = newValue }
    }
    /// Set by GroupView: a joined side loses its radius and its border (`rounded-s-none border-s-0`).
    public var joinedSides: (leading: Bool, trailing: Bool) = (false, false) {
        didSet { restyle(); invalidateIntrinsicContentSize() }
    }

    private let decoration = BoxDecorationLayer()
    private let label = LabelView()
    private var leadingIconView: NSView?
    private var trailingIconView: IconView?

    public convenience init(_ title: String? = nil, icon: IconName? = nil, variant: Variant = .default, size: Size = .default) {
        self.init(frame: .zero)
        self.variant = variant
        self.size = size
        self.title = title
        label.text = title ?? ""
        syncLabel()
        self.icon = icon
        updateIcons()
        restyle()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        decoration.transition = [.shadow] // transition-[box-shadow,scale] (button.tsx:11): the focus ring fades, hover fills snap
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        label.font = DSFont.ui(14, weight: .medium)
        restyle()
    }

    /// An empty label stays out of the view tree. Its zero-size layer can't hold contents, so Core
    /// Animation displayed it again in every commit, hidden or not: 55 of the layer displays while
    /// an answer with code blocks streamed (docs/perf/README.md, "Streaming text").
    private func syncLabel() {
        if label.text.isEmpty {
            label.removeFromSuperview()
        } else if label.superview !== self {
            addSubview(label)
        }
    }

    // MARK: Layout

    public override var intrinsicContentSize: NSSize {
        var m = size.metrics
        if let iconSize { m.icon = iconSize }
        let joined = CGFloat((joinedSides.leading ? 1 : 0) + (joinedSides.trailing ? 1 : 0))
        if size.isIconOnly { return NSSize(width: m.height - joined, height: m.height) }
        // CSS: padding and the 1px border on both sides, plus the exact text advance.
        var width = 2 * (m.padding + 1) + labelSlotWidth - joined
        let icons = [leadingIconView, trailingIconView].compactMap { $0 }
        // Icons carry `-mx-0.5`, so each takes its size minus 4px of inline space.
        width += icons.reduce(0) { total, _ in total + m.icon - 4 + m.gap }
        if let accessory { width += accessory.intrinsicContentSize.width + m.gap }
        if title?.isEmpty ?? true, !icons.isEmpty { width -= m.gap }
        // ponytail: Chromium snaps the border box to device pixels; this assumes a 2x backing store, use the window's scale if 1x screens matter
        return NSSize(width: (width * 2).rounded() / 2, height: m.height)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        var m = size.metrics
        if let iconSize { m.icon = iconSize }
        let iconY = (bounds.height - m.icon) / 2
        if size.isIconOnly {
            leadingIconView?.frame = NSRect(x: (bounds.width - m.icon) / 2, y: iconY, width: m.icon, height: m.icon)
            return
        }
        // Content is centered as a group, like `justify-center` with `gap`.
        let labelWidth = title?.isEmpty ?? true ? 0 : label.textWidth
        let slotWidth = labelWidth > 0 ? labelSlotWidth : 0
        var parts: [CGFloat] = []
        if leadingIconView != nil { parts.append(m.icon - 4) }
        if slotWidth > 0 { parts.append(slotWidth) }
        let accessoryWidth = accessory?.intrinsicContentSize.width ?? 0
        if accessory != nil { parts.append(accessoryWidth) }
        if trailingIconView != nil { parts.append(m.icon - 4) }
        let total = parts.reduce(0, +) + m.gap * CGFloat(max(0, parts.count - 1))
        var x = (bounds.width - total) / 2 + CGFloat((joinedSides.leading ? 0 : 1) - (joinedSides.trailing ? 0 : 1)) / 2
        if let leading = leadingIconView {
            leading.frame = NSRect(x: x - 2, y: iconY, width: m.icon, height: m.icon)
            x += m.icon - 4 + m.gap
        }
        // The button's `text-align: center` centers the shown label in its slot.
        label.frame = NSRect(x: x + (slotWidth - labelWidth) / 2, y: (bounds.height - m.line) / 2, width: labelWidth, height: m.line)
        x += slotWidth + (slotWidth > 0 ? m.gap : 0)
        if let accessory {
            let h = accessory.intrinsicContentSize.height
            accessory.frame = NSRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: accessoryWidth, height: h)
            x += accessoryWidth + m.gap
        }
        trailingIconView?.frame = NSRect(x: x - 2, y: iconY, width: m.icon, height: m.icon)
        if justifiesBetween {
            label.frame.origin.x = m.padding + 1
            trailingIconView?.frame.origin.x = bounds.width - m.padding - 1 - m.icon + 2
        }
    }

    /// `AnimatedWidth` (AnimatedWidth.tsx, T3 3105 6a68bee34): call after the frame changed from `oldWidth` with the
    /// right edge kept. The box grows or shrinks to its new width over 150 ms `ease-out`, the leading icon and the
    /// label ride its left edge, and a growing label is clipped where its slot ends, not ellipsized.
    public func animateWidth(from oldWidth: CGFloat) {
        layoutSubtreeIfNeeded()
        let d = bounds.width - oldWidth
        guard d != 0, window != nil, !Motion.reduced else { return }
        let timing = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1) // Tailwind 4 `ease-out`
        func slide(_ layer: CALayer?, _ key: String, from: CGFloat, to: CGFloat) {
            guard let layer else { return }
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = 0.15
            a.timingFunction = timing
            layer.add(a, forKey: "animatedWidth.\(key)")
        }
        // A running style fade (the press, the focus ring) draws its old snapshot at the old size: it snaps instead.
        decoration.removeAnimation(forKey: kCATransition)
        slide(decoration, "bounds.size.width", from: decoration.bounds.width - d, to: decoration.bounds.width)
        slide(decoration, "position.x", from: decoration.position.x + d / 2, to: decoration.position.x)
        for view in [leadingIconView, title?.isEmpty == false ? label : nil].compactMap({ $0 }) {
            slide(view.layer, "position.x", from: view.layer!.position.x + d, to: view.layer!.position.x)
        }
        guard d > 0, let labelLayer = label.layer, label.superview === self else { return }
        // The label slot ends where it ends at rest; the moving label shows only up to there.
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = CGRect(x: -bounds.width, y: -bounds.height, width: bounds.width + labelLayer.bounds.width, height: 3 * bounds.height)
        labelLayer.mask = mask
        CATransaction.begin()
        // Core Animation runs the completion on the main thread.
        nonisolated(unsafe) let held = (labelLayer, mask)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { if held.0.mask === held.1 { held.0.mask = nil } } }
        slide(mask, "position.x", from: mask.position.x - d, to: mask.position.x)
        CATransaction.commit()
    }

    /// The label's width, or the widest reserved title's.
    private var labelSlotWidth: CGFloat {
        reservedTitles.reduce(label.textWidth) { widest, title in
            max(widest, TextLine(NSAttributedString(string: title, attributes: [.font: label.font])).width)
        }
    }

    /// Turns the leading icon, for a disclosure chevron with `transition-transform` (see `IconView.setRotation`).
    public func setIconRotation(_ degrees: CGFloat, motion: IconView.RotationMotion = .ease(0.15)) {
        (leadingIconView as? IconView)?.setRotation(degrees, motion: motion)
    }

    private func updateIcons() {
        leadingIconView?.removeFromSuperview()
        trailingIconView?.removeFromSuperview()
        if showsSpinner {
            leadingIconView = SpinnerView()
        } else {
            leadingIconView = icon.map { IconView(name: $0) } ?? iconDefinition.map { IconView(definition: $0) }
        }
        trailingIconView = trailingIcon.map { IconView(name: $0) }
        [leadingIconView, trailingIconView].compactMap { $0 }.forEach(addSubview)
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: Styling

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }

    private func restyle() {
        let m = size.metrics
        label.font = monospaced ? DSFont.mono(m.font, weight: .medium) : DSFont.ui(m.font, weight: .medium)
        label.lineHeight = m.line
        var look = ButtonStyles.look(variant: variant, state: state, radius: m.radius)
        if joinedSides.leading || joinedSides.trailing {
            var corners = BoxStyle.Corners.all
            if joinedSides.leading { corners.subtract(.leading) }
            if joinedSides.trailing { corners.subtract(.trailing) }
            look.box.corners = corners
            look.box.borderEdges = .init(top: 1, left: joinedSides.leading ? 0 : 1, bottom: 1, right: joinedSides.trailing ? 0 : 1)
        }
        decoration.boxStyle = look.box
        label.color = look.text
        for iconView in [leadingIconView, trailingIconView].compactMap({ $0 }) {
            (iconView as? IconView)?.strokeColor = iconColor ?? look.icon
            (iconView as? SpinnerView)?.color = iconColor ?? look.icon
        }
        if variant == .link {
            label.isUnderlined = state.hoverOrPressed
        }
        needsLayout = true
    }

}

/// Resolved visuals per variant and state (ui-components-a.md 2.4).
@MainActor
enum ButtonStyles {
    struct Look {
        var box = BoxStyle()
        var text: NSColor
        var icon: NSColor
    }

    static func look(variant: ButtonView.Variant, state: ControlView.State, radius: CGFloat) -> Look {
        let fg = Themed.color(\.contrastForeground)
        let muted = Themed.color(\.contrastMutedForeground)
        var box = BoxStyle()
        box.radius = radius
        var look = Look(text: fg, icon: fg)
        let pressed = state.activeOrPressed
        let hover = state.hoverOrPressed

        switch variant {
        case .default, .destructive:
            let base: KeyPath<Palette, TokenColor> = variant == .default ? \.primary : \.destructive
            box.border = Themed.color(base)
            box.fill = Themed.color(base, hover ? 0.9 : 1)
            look.text = variant == .default ? Themed.color(\.primaryForeground) : Themed.textOn(\.destructive)
            look.icon = look.text
            if state.enabled {
                box.shadows.append(BoxShadow(y: 1, color: pressed ? Themed.black(0.08) : Themed.white(0.16), inset: true))
            }
            if state.enabled && !pressed {
                box.shadows.append(BoxShadow(y: 1, blur: 2, color: Themed.color(base, 0.24)))
            }

        case .outline, .destructiveOutline:
            box.border = Themed.color(\.contrastInput)
            box.backgroundClip = .paddingInLight // `not-dark:bg-clip-padding`
            if variant == .outline {
                box.fill = hover
                    ? Themed.color(light: \.accent, 0.5, dark: \.contrastInput, 0.64)
                    : Themed.color(light: \.popover, 1, dark: \.contrastInput, 0.32)
                look.icon = muted
            } else {
                box.fill = hover
                    ? Themed.color(\.destructive, 0.04)
                    : Themed.color(light: \.popover, 1, dark: \.contrastInput, 0.32)
                if hover { box.border = Themed.color(\.destructive, 0.32) }
                look.text = Themed.color(\.destructiveForeground)
                look.icon = look.text
            }
            if state.enabled && !pressed {
                box.shadows.append(BoxShadow(y: 1, blur: 2, color: Themed.black(0.05)))
                box.beforeShadows.append(BoxShadow(y: 1, color: Themed.pick(light: Themed.black(0.04),
                                                                            dark: .clear)))
                box.beforeShadows.append(BoxShadow(y: -1, color: Themed.pick(light: .clear,
                                                                             dark: Themed.white(0.06))))
            } else if state.enabled {
                box.beforeShadows.append(BoxShadow(y: -1, color: Themed.pick(light: .clear,
                                                                             dark: Themed.white(0.02))))
            }

        case .ghost, .ghostMuted, .ghostDestructive:
            box.border = .clear
            if hover { box.fill = Themed.color(\.accent) }
            switch variant {
            case .ghost:
                look.text = fg
                look.icon = muted
            case .ghostMuted:
                look.text = hover ? fg : muted
                look.icon = look.text
            default:
                look.text = hover ? Themed.color(\.destructive) : muted
                look.icon = look.text
            }

        case .secondary:
            box.border = .clear
            box.fill = Themed.color(\.secondary, hover ? 0.9 : (state.active ? 0.8 : 1))
            look.text = Themed.color(\.secondaryForeground)
            look.icon = look.text

        case .warningOutline:
            box.border = Themed.color(\.warning, hover ? 0.40 : 0.32)
            box.fill = hover ? Themed.color(light: \.warning, 0.16, dark: \.warning, 0.24) : Themed.color(\.warningSurface)
            look.text = Themed.color(\.warningForeground)
            look.icon = look.text
            if state.enabled && !pressed { box.shadows.append(BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))) }

        case .glass:
            // ponytail: solid 80% background instead of a live backdrop blur (docs/design.md substitutions)
            box.radius = 9999
            box.fill = Themed.color(\.background, Double(ThemeRuntime.glassOpacity))
            box.border = Themed.color(\.border, hover ? 1 : 0.6)
            look.icon = muted
            box.shadows.append(BoxShadow(y: 1, blur: 3, color: Themed.black(0.1)))
            box.shadows.append(BoxShadow(y: 1, blur: 2, spread: -1, color: Themed.black(0.1)))

        case .link:
            box.border = .clear

        case .mediaClose:
            box.border = .clear
            box.fill = Themed.black(hover ? 0.8 : 0.65)
            look.text = Themed.white(1)
            look.icon = look.text
            box.shadows.append(BoxShadow(spread: 1, color: Themed.white(0.2)))
            box.shadows.append(BoxShadow(y: 1, blur: 3, color: Themed.black(0.1)))
            box.shadows.append(BoxShadow(y: 1, blur: 2, spread: -1, color: Themed.black(0.1)))

        case .mediaNavigation:
            box.border = .clear
            if hover { box.fill = Themed.white(0.1) }
            look.text = Themed.white(hover ? 1 : 0.9)
            look.icon = look.text

        case .overlay:
            box.border = .clear
            box.fill = Themed.black(hover ? 0.9 : 0.7)
            look.text = Themed.white(0.65)
            look.icon = look.text
        }

        if state.focusVisible {
            let ringColor = variant == .mediaClose || variant == .mediaNavigation ? Themed.white(1) : Themed.color(\.ring)
            // media-navigation sets `focus-visible:ring-offset-transparent`, so its ring shows through the offset.
            let offsetColor = variant == .mediaNavigation ? NSColor.clear : Themed.color(\.background)
            box.shadows = BoxShadow.focusRing(ring: ringColor, offset: offsetColor) + box.shadows
        }
        look.box = box
        return look
    }
}
