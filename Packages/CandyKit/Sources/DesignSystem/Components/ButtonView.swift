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
    public var title: String? { didSet { label.text = title ?? ""; invalidateIntrinsicContentSize() } }
    public var icon: IconName? { didSet { updateIcons() } }
    public var trailingIcon: IconName? { didSet { updateIcons() } }
    /// An explicit icon class such as `size-3`, which beats the size's default icon size.
    public var iconSize: CGFloat? { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    /// Set by GroupView: a joined side loses its radius and its border (`rounded-s-none border-s-0`).
    public var joinedSides: (leading: Bool, trailing: Bool) = (false, false) {
        didSet { restyle(); invalidateIntrinsicContentSize() }
    }

    private let decoration = BoxDecorationLayer()
    private let label = LabelView()
    private var leadingIconView: IconView?
    private var trailingIconView: IconView?

    public convenience init(_ title: String? = nil, icon: IconName? = nil, variant: Variant = .default, size: Size = .default) {
        self.init(frame: .zero)
        self.variant = variant
        self.size = size
        self.title = title
        label.text = title ?? ""
        self.icon = icon
        updateIcons()
        restyle()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        label.font = DSFont.ui(14, weight: .medium)
        addSubview(label)
        restyle()
    }

    // MARK: Layout

    public override var intrinsicContentSize: NSSize {
        var m = size.metrics
        if let iconSize { m.icon = iconSize }
        let joined = CGFloat((joinedSides.leading ? 1 : 0) + (joinedSides.trailing ? 1 : 0))
        if size.isIconOnly { return NSSize(width: m.height - joined, height: m.height) }
        // CSS: padding and the 1px border on both sides, plus the exact text advance.
        var width = 2 * (m.padding + 1) + label.textWidth - joined
        let icons = [leadingIconView, trailingIconView].compactMap { $0 }
        // Icons carry `-mx-0.5`, so each takes its size minus 4px of inline space.
        width += icons.reduce(0) { total, _ in total + m.icon - 4 + m.gap }
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
        var parts: [CGFloat] = []
        if leadingIconView != nil { parts.append(m.icon - 4) }
        if labelWidth > 0 { parts.append(labelWidth) }
        if trailingIconView != nil { parts.append(m.icon - 4) }
        let total = parts.reduce(0, +) + m.gap * CGFloat(max(0, parts.count - 1))
        var x = (bounds.width - total) / 2 + CGFloat((joinedSides.leading ? 0 : 1) - (joinedSides.trailing ? 0 : 1)) / 2
        if let leading = leadingIconView {
            leading.frame = NSRect(x: x - 2, y: iconY, width: m.icon, height: m.icon)
            x += m.icon - 4 + m.gap
        }
        label.frame = NSRect(x: x, y: (bounds.height - m.line) / 2, width: labelWidth, height: m.line)
        x += labelWidth + (labelWidth > 0 ? m.gap : 0)
        trailingIconView?.frame = NSRect(x: x - 2, y: iconY, width: m.icon, height: m.icon)
    }

    private func updateIcons() {
        leadingIconView?.removeFromSuperview()
        trailingIconView?.removeFromSuperview()
        leadingIconView = icon.map { IconView(name: $0) }
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
        label.font = DSFont.ui(m.font, weight: .medium)
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
            iconView.strokeColor = look.icon
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
            look.text = variant == .default ? Themed.color(\.primaryForeground) : Themed.white(1)
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
            box.fill = Themed.color(\.background, 0.8)
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
