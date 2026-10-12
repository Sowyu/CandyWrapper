import AppKit

/// T3's `Toggle` (`apps/web/src/components/ui/toggle.tsx`), desktop values.
/// Spec: docs/research/recovered/ui-components-b.md section 1. `isPressed` is Base UI's `data-pressed`.
public final class ToggleView: ControlView {
    public enum Variant: String, CaseIterable, Sendable { case `default`, pill, ghost, outline, segmented }

    public enum Size: String, CaseIterable, Sendable {
        case `default`, sm, xs, lg, compact, segmented

        /// Height, min-width, inline padding, radius. Text is 14/20 and icons 16px at every size on
        /// desktop: the base `sm:text-sm` and `sm:[&_svg]:size-4` outlive the size-level overrides.
        var metrics: (height: CGFloat, minWidth: CGFloat, padding: CGFloat, radius: CGFloat) {
            switch self {
            case .default: (32, 32, 7, 10)
            case .sm: (28, 28, 5, 10)
            case .xs: (24, 24, 3, 8)
            case .lg: (36, 36, 9, 10)
            case .compact: (28, 28, 3, 8)
            case .segmented: (24, 0, 10, 8)
            }
        }
    }

    public var variant: Variant = .default { didSet { restyle(); invalidateIntrinsicContentSize() } }
    public var size: Size = .default { didSet { restyle(); invalidateIntrinsicContentSize() } }
    public var title: String? { didSet { label.text = title ?? ""; invalidateIntrinsicContentSize(); needsLayout = true } }
    public var icon: IconName? { didSet { updateIcon() } }
    /// Icon size for icons with their own `size-*` class (16 otherwise).
    public var iconSize: CGFloat = 16 { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    public var isPressed = false { didSet { if isPressed != oldValue { restyle(); setAccessibilityValue(isPressed) } } }
    /// `font-mono` on the label (the content search options).
    public var monospaced = false { didSet { restyle(); invalidateIntrinsicContentSize() } }
    /// `underline decoration-2 underline-offset-2` on the label (the content search's "ab").
    public var underlinesTitle = false { didSet { label.underlineDecoration = underlinesTitle ? (2, 2) : nil } }
    /// Called after a click flips `isPressed`.
    public final var onPressedChange: (@MainActor (Bool) -> Void)?

    private let decoration = BoxDecorationLayer()
    private let label = LabelView()
    private var iconView: IconView?

    public convenience init(_ title: String? = nil, icon: IconName? = nil, variant: Variant = .default,
                            size: Size = .default, pressed: Bool = false) {
        self.init(frame: .zero)
        self.variant = variant
        self.size = size
        self.title = title
        label.text = title ?? ""
        self.isPressed = pressed
        self.icon = icon
        updateIcon()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false // no press scale on toggles
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        addSubview(label)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.toggle)
        restyle()
    }

    public override func performAction() {
        isPressed.toggle()
        onPressedChange?(isPressed)
        super.performAction()
    }

    // MARK: Layout

    private var radius: CGFloat { variant == .pill ? 9999 : size.metrics.radius }
    private var padding: CGFloat { variant == .pill ? 12 : size.metrics.padding }
    private var hasTitle: Bool { !(title?.isEmpty ?? true) }

    private var contentWidth: CGFloat {
        var parts: [CGFloat] = []
        if iconView != nil { parts.append(iconSize - 4) } // the icon with `-mx-0.5`
        if hasTitle { parts.append(label.textWidth) }
        return parts.reduce(0, +) + 8 * CGFloat(max(0, parts.count - 1))
    }

    /// Unsnapped CSS width, for groups that place items at fractional x like Chromium.
    var exactWidth: CGFloat { max(size.metrics.minWidth, 2 * (padding + 1) + contentWidth) }

    public override var intrinsicContentSize: NSSize {
        let m = size.metrics
        let width = exactWidth
        // ponytail: snaps to 2x device pixels like ButtonView, use the window's scale if 1x screens matter
        return NSSize(width: (width * 2).rounded() / 2, height: m.height)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        var x = (bounds.width - contentWidth) / 2
        if let iconView {
            iconView.frame = NSRect(x: x - 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            x += iconSize - 4 + 8
        }
        label.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: hasTitle ? label.textWidth : 0, height: 20)
    }

    private func updateIcon() {
        iconView?.removeFromSuperview()
        iconView = icon.map { IconView(name: $0) }
        iconView.map(addSubview)
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
        label.font = monospaced ? DSFont.mono(14, weight: .medium) : DSFont.ui(14, weight: variant == .pill ? .regular : .medium)
        label.lineHeight = 20
        disabledOpacity = variant == .ghost ? 1 : 0.64 // ghost: `disabled:opacity-100`
        alphaValue = state.enabled ? 1 : CGFloat(disabledOpacity)
        // toggle.tsx:9 `transition-shadow` fades the focus ring; the segmented variant's `transition-colors`
        // (toggle.tsx:34) replaces it through tailwind-merge and fades text, icon and background instead.
        transitions = variant == .segmented ? .colors : []
        decoration.transition = variant == .segmented ? [] : [.shadow]
        let look = ToggleStyles.look(variant: variant, state: state, pressed: isPressed, radius: radius)
        Motion.transitioning(transitions) {
            decoration.boxStyle = look.box
            label.color = look.text
            iconView?.strokeColor = look.text
        }
        // `[&_svg]:opacity-80`, as group opacity like CSS. Ghost's `disabled:[&_svg]:opacity-100` loses
        // to it on specificity (the base selector has `:not([class*='opacity-'])`).
        iconView?.alphaValue = 0.8
        needsLayout = true
    }
}

@MainActor
enum ToggleStyles {
    static func look(variant: ToggleView.Variant, state: ControlView.State, pressed: Bool, radius: CGFloat) -> (box: BoxStyle, text: NSColor) {
        var box = BoxStyle()
        box.radius = radius
        box.border = .clear
        let fg = Themed.color(\.contrastForeground)
        let muted = Themed.color(\.contrastMutedForeground)
        let accentFg = Themed.color(\.contrastAccentForeground)
        let hover = state.hovered
        var text = fg

        switch variant {
        case .default, .pill:
            if hover { box.fill = Themed.color(\.accent) }
            if pressed { box.fill = Themed.color(\.contrastInput, 0.64) }
            if variant == .default {
                text = pressed ? accentFg : fg
            } else {
                text = pressed ? fg : muted
            }

        case .ghost:
            if hover || pressed { box.fill = Themed.color(\.accent) }
            // `data-pressed:text-accent-foreground` comes after `disabled:text-muted-foreground` in the CSS.
            text = pressed ? accentFg : (state.enabled ? fg : muted)

        case .outline:
            box.border = Themed.color(\.contrastInput)
            box.backgroundClip = .paddingInLight
            if pressed {
                box.fill = Themed.color(light: \.contrastInput, 0.64, dark: \.contrastInput, 1)
            } else if hover {
                box.fill = Themed.color(light: \.accent, 1, dark: \.contrastInput, 0.64)
            } else {
                box.fill = Themed.color(light: \.background, 1, dark: \.contrastInput, 0.32)
            }
            text = pressed ? accentFg : fg
            let quiet = state.enabled && !state.active && !pressed
            if quiet { box.shadows.append(BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))) }
            if quiet {
                box.beforeShadows.append(BoxShadow(y: 1, color: Themed.pick(light: Themed.black(0.04), dark: .clear)))
                box.beforeShadows.append(BoxShadow(y: -1, color: Themed.pick(light: .clear, dark: Themed.white(0.06))))
            } else if state.enabled && !pressed {
                box.beforeShadows.append(BoxShadow(y: -1, color: Themed.pick(light: .clear, dark: Themed.white(0.02))))
            }

        case .segmented:
            if pressed {
                box.fill = Themed.color(light: \.background, 1, dark: \.contrastInput, 0.72)
                box.shadows.append(BoxShadow(y: 1, blur: 2, color: Themed.black(0.1)))
            } else if hover {
                box.fill = Themed.color(light: \.background, 0.55, dark: \.contrastInput, 0.32)
            }
            text = pressed || hover ? fg : muted
        }

        if state.focusVisible {
            box.shadows = BoxShadow.focusRing(ring: Themed.color(\.ring), offset: Themed.color(\.background)) + box.shadows
        }
        return (box, text)
    }
}

/// T3's `ToggleGroup` (`toggle-group.tsx`), single selection like Base UI's default.
/// Spec: ui-components-b.md section 2. Items take the group's variant and size.
public final class ToggleGroupView: DSView {
    public enum Variant: String, Sendable { case segmented, `default` }

    public let variant: Variant
    public private(set) var items: [ToggleView] = []
    /// Index of the pressed item, nil when none is.
    public var selectedIndex: Int? {
        didSet { for (i, item) in items.enumerated() { item.isPressed = i == selectedIndex } }
    }
    public final var onChange: (@MainActor (Int?) -> Void)?

    private let track = BoxDecorationLayer()

    /// ponytail: segmented and default only; the joined outline/ghost/pill bar needs per-corner radii
    /// and per-side borders in BoxStyle, add when a screen uses it (ScheduledTasksSettings.tsx:1299)
    public init(variant: Variant = .segmented, items titles: [(title: String?, icon: IconName?)], selected: Int? = nil) {
        self.variant = variant
        super.init(frame: .zero)
        track.host = self
        layer?.addSublayer(track)
        layer?.masksToBounds = false
        items = titles.enumerated().map { i, item in
            let toggle = ToggleView(item.title, icon: item.icon,
                                    variant: variant == .segmented ? .segmented : .default,
                                    size: variant == .segmented ? .segmented : .default)
            toggle.onPressedChange = { [weak self] pressed in self?.itemChanged(i, pressed) }
            return toggle
        }
        items.forEach(addSubview)
        selectedIndex = selected
        for (i, item) in items.enumerated() { item.isPressed = i == selected }
        setAccessibilityRole(.group)
    }

    private func itemChanged(_ index: Int, _ pressed: Bool) {
        selectedIndex = pressed ? index : nil
        onChange?(selectedIndex)
    }

    private var inset: CGFloat { variant == .segmented ? 2 : 0 }
    /// `*:flex-1`: the items share the group's width equally instead of hugging their labels.
    public var fillsWidth = false { didSet { needsLayout = true } }

    public override var intrinsicContentSize: NSSize {
        let width = items.map(\.exactWidth).reduce(0, +) + 2 * CGFloat(max(0, items.count - 1)) + 2 * inset
        let height = items.map(\.intrinsicContentSize.height).max() ?? 0
        return NSSize(width: Self.snap(width), height: height + 2 * inset)
    }

    public override func layout() {
        super.layout()
        track.layout(boxSize: bounds.size)
        var x = inset
        let shared = (bounds.width - 2 * inset - 2 * CGFloat(max(0, items.count - 1))) / CGFloat(max(1, items.count))
        for item in items {
            // Chromium keeps fractional positions and snaps each edge to device pixels.
            let w = fillsWidth ? shared : item.exactWidth
            item.frame = NSRect(x: Self.snap(x), y: inset, width: Self.snap(x + w) - Self.snap(x),
                                height: item.intrinsicContentSize.height)
            x += w + 2 // gap-0.5
        }
    }

    // ponytail: 2x device pixels, like ButtonView; use the window's scale if 1x screens matter
    static func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

    public override func updateLayer() {
        var box = BoxStyle()
        if variant == .segmented {
            box.radius = 10
            box.fill = Themed.color(\.contrastInput, 0.4)
        }
        track.boxStyle = box
        track.setNeedsDisplay()
    }
}
