import AppKit

/// T3's `Select` (`select.tsx`): a trigger that shows the value and a popup list aligned so the
/// selected item sits over the trigger, like a macOS pop-up button. Desktop values.
/// Spec: docs/research/recovered/ui-components-a.md section 9.
public final class SelectView: ControlView {
    public enum Variant: String, CaseIterable, Sendable { case `default`, ghost }
    public enum Size: String, CaseIterable, Sendable {
        case xs, compact, sm, `default`, lg
        /// Height, inline padding, gap, radius, font px, line height, chevron margin.
        var metrics: (height: CGFloat, padding: CGFloat, gap: CGFloat, radius: CGFloat, font: CGFloat, line: CGFloat) {
            switch self {
            case .xs: (24, 7, 4, 8, 12, 16)
            case .compact: (28, 7, 4, 8, 14, 20) // tailwind-merge quirk keeps sm:text-sm
            case .sm: (28, 9, 6, 10, 14, 20)
            case .default: (32, 11, 8, 10, 14, 20)
            case .lg: (36, 11, 8, 10, 14, 20)
            }
        }
    }

    public var options: [String] { didSet { invalidateIntrinsicContentSize() } }
    public var selectedIndex: Int? { didSet { updateValue() } }
    public var placeholder: String { didSet { updateValue() } }
    public var variant: Variant { didSet { restyle() } }
    public var size: Size { didSet { restyle(); invalidateIntrinsicContentSize() } }
    public var isInvalid = false { didSet { restyle() } }
    public final var onChange: (@MainActor (Int) -> Void)?
    /// `alignItemWithTrigger`; false opens a plain dropdown at `popupAlign` (T3's settings selects use `end`).
    public var alignItemWithTrigger = true
    public var popupAlign: PopupPlacement.Align = .start
    /// `hideIndicator`: items without the check mark.
    public var hidesIndicator = false
    /// `w-auto`: the trigger is as wide as its value instead of filling its container.
    public var fitsContent = false { didSet { invalidateIntrinsicContentSize() } }
    /// A settings row's select, which Dither draws after Capy's: as wide as its value (`ditherSettingsMetrics`), 14pt
    /// foreground text on a fill a step lighter than the card, a faint light rim and a 16pt chevron. Other themes keep
    /// T3's trigger at the width it was given.
    public var ditherSettings = false { didSet { restyle(); invalidateIntrinsicContentSize() } }
    /// Capy's settings select, measured at 2x: 11pt in, the value, 8pt to the chevron's 8pt glyph, 8pt out.
    static let ditherSettingsMetrics = (padding: CGFloat(11), gap: CGFloat(8), chevron: CGFloat(16), trailing: CGFloat(8))
    private var ditherStyled: Bool {
        ditherSettings && variant == .default && ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
    }
    /// A view before the value (`SelectTrigger` children such as an icon), `gap` from it.
    public var leading: NSView? { didSet { oldValue?.removeFromSuperview(); leading.map(addSubview); invalidateIntrinsicContentSize(); needsLayout = true } }
    /// Items' subtitles in the popup (`SelectItem` with a description line).
    public var optionDetails: [String?] = []
    /// Items' 12px leading glyphs (`SelectItem` children with an icon, `gap-1.5`).
    public var optionGlyphs: [IconDefinition?] = []
    /// `SelectPopup side`, read when `alignItemWithTrigger` is false.
    public var popupSide: PopupPlacement.Side = .bottom
    /// Disabled items by index.
    public var disabledOptions: Set<Int> = []
    /// `SelectGroupLabel` rows, each shown before the option at its key.
    public var groupLabels: [Int: String] = [:]
    /// Muted text at the end of each item (`justify-between gap-5`).
    public var optionTrailingDetails: [String?] = []
    /// What the trigger shows for each option when it differs from the item (`SelectValue` children).
    public var valueLabels: [String]? { didSet { updateValue() } }

    private let decoration = BoxDecorationLayer()
    private let label = LabelView()
    private let chevron = IconView(name: .chevronDown, size: 12)
    private weak var openList: MenuPopupView?

    public init(options: [String], selected: Int? = nil, placeholder: String = "", variant: Variant = .default, size: Size = .default) {
        self.options = options
        self.selectedIndex = selected
        self.placeholder = placeholder
        self.variant = variant
        self.size = size
        super.init(frame: .zero)
        scalesWhenPressed = false // aria-haspopup
        opensPopupOnPress = true
        // `transition-[color,box-shadow,background-color]` (select.tsx:14). The border joins the fade because
        // focus swaps it together with the ring, and one cross-fade cannot snap part of a box.
        transitions = [.color, .background, .shadow, .border]
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.popUpButton)
        updateValue()
    }

    private func updateValue() {
        label.text = selectedIndex.map { i in
            if let v = valueLabels, v.indices.contains(i) { return v[i] }
            return options.indices.contains(i) ? options[i] : placeholder
        } ?? placeholder
        restyle()
        invalidateIntrinsicContentSize()
    }

    /// `w-full min-w-36`: the trigger fills its container, so it has no intrinsic width.
    public override var intrinsicContentSize: NSSize {
        let m = size.metrics
        if ditherStyled {
            let d = Self.ditherSettingsMetrics
            let lead = leading.map { $0.frame.width + m.gap } ?? 0
            // The 16pt chevron box draws an 8pt glyph centred in it, so 4pt of the box sits in each margin.
            return NSSize(width: ceil(d.padding + lead + ceil(label.textWidth) + d.gap + d.chevron - 8 + d.trailing), height: m.height)
        }
        guard fitsContent else { return NSSize(width: NSView.noIntrinsicMetric, height: m.height) }
        let lead = leading.map { $0.frame.width + m.gap } ?? 0
        return NSSize(width: ceil(2 + 2 * m.padding + lead + ceil(label.textWidth) + m.gap + (DesignGeometry.usesClassic(self) ? 12 : 14) - 4), height: m.height)
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let m = size.metrics
        if ditherStyled {
            let d = Self.ditherSettingsMetrics
            let chevronX = bounds.width - d.trailing + 4 - d.chevron
            chevron.frame = NSRect(x: chevronX, y: (bounds.height - d.chevron) / 2, width: d.chevron, height: d.chevron)
            var x = d.padding
            if let leading {
                leading.frame.origin = NSPoint(x: x, y: ((bounds.height - leading.frame.height) / 2).rounded())
                x += leading.frame.width + m.gap
            }
            label.frame = NSRect(x: x, y: (bounds.height - m.line) / 2, width: max(0, chevronX + 4 - d.gap - x), height: m.line)
            return
        }
        let glyph: CGFloat = DesignGeometry.usesClassic(self) ? 12 : 14
        let chevronX = bounds.width - 1 - m.padding + 4 - glyph
        chevron.frame = NSRect(x: chevronX, y: (bounds.height - glyph) / 2, width: glyph, height: glyph)
        var x = 1 + m.padding
        if let leading {
            leading.frame.origin = NSPoint(x: x, y: ((bounds.height - leading.frame.height) / 2).rounded())
            x += leading.frame.width + m.gap
        }
        label.frame = NSRect(x: x, y: (bounds.height - m.line) / 2, width: max(0, chevronX - m.gap - x), height: m.line)
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        restyle()
    }

    private func restyle() {
        let m = size.metrics
        label.font = DSFont.ui(m.font)
        label.lineHeight = m.line
        var box = BoxStyle()
        box.radius = size == .xs || size == .compact ? m.radius : DesignGeometry.radius(m.radius, in: self)
        let placeholderShown = selectedIndex == nil
        switch variant {
        case .default:
            box.fill = Themed.color(light: \.background, 1, dark: \.contrastInput, 0.32)
            box.backgroundClip = .paddingInLight
            box.border = isInvalid ? Themed.color(\.destructive, state.focusVisible ? 0.64 : 0.36)
                : (state.focusVisible ? Themed.color(\.ring) : Themed.color(\.contrastInput))
            let quiet = !state.enabled || state.focusVisible || isInvalid || state.popupOpen
            if !quiet {
                box.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
                box.beforeShadows = [BoxShadow(y: 1, color: Themed.pick(light: Themed.black(0.04), dark: .clear)),
                                     BoxShadow(y: -1, color: Themed.pick(light: .clear, dark: Themed.white(0.06)))]
            }
            if state.focusVisible {
                let ring = isInvalid ? Themed.color(light: \.destructive, 0.16, dark: \.destructive, 0.24) : Themed.color(\.ring, 0.24)
                box.shadows = [BoxShadow(spread: 3, color: ring)]
            }
            label.color = placeholderShown ? Themed.color(\.contrastPlaceholder) : Themed.color(\.contrastForeground)
            chevron.strokeColor = Themed.color(\.contrastIconMuted)
        case .ghost:
            box.border = .clear
            if state.hoverOrPressed { box.fill = Themed.color(\.accent) }
            if state.focusVisible { box.shadows = [BoxShadow(spread: 2, color: Themed.color(\.ring))] }
            label.color = state.hoverOrPressed ? Themed.color(\.contrastForeground) : Themed.color(\.contrastSecondaryLabel)
            if placeholderShown { label.color = Themed.color(\.contrastPlaceholder) }
            chevron.strokeColor = label.color
        }
        chevron.alphaValue = DesignGeometry.usesClassic(self) ? 0.5 : 0.7
        if ditherStyled {
            // Measured on Capy in dark: the fill #292929 on a #222 card, a #3e3e3e 1pt rim, #ececec text.
            box.fill = Themed.color(light: \.foreground, 0.03, dark: \.foreground, 0.035)
            box.backgroundClip = .border
            box.beforeShadows = []
            if !state.focusVisible {
                box.shadows = []
                box.border = isInvalid ? box.border : Themed.color(light: \.foreground, 0.1, dark: \.foreground, 0.1)
            }
            if state.hoverOrPressed || state.popupOpen { box.fill = Themed.color(light: \.foreground, 0.05, dark: \.foreground, 0.065) }
            label.color = placeholderShown ? Themed.color(\.placeholder) : Themed.color(\.foreground)
            chevron.strokeColor = Themed.color(\.mutedForeground)
        }
        decoration.boxStyle = box
        needsLayout = true
    }

    // MARK: Popup

    /// base-ui Select: a release on another item counts after 200 ms, on the selected item after 400 ms,
    /// and after 400 ms for both when nothing is selected (SelectTrigger.js:104-128).
    public override func dragSelectDelay(row: Int, in menu: PressDragMenu) -> TimeInterval {
        guard let selectedIndex else { return 0.4 }
        return row == selectedIndex ? 0.4 : 0.2
    }

    public override func performAction() {
        super.performAction()
        guard let host = popupHost else { return }
        var items: [MenuItem] = []
        var optionAt: [Int: Int] = [:]
        for (i, title) in options.enumerated() {
            if let group = groupLabels[i] { items.append(.label(group)) }
            var item = MenuItem(title, kind: hidesIndicator ? .item : .radio(i == selectedIndex))
            item.subtitle = optionDetails.indices.contains(i) ? optionDetails[i] : nil
            item.glyph = optionGlyphs.indices.contains(i) ? optionGlyphs[i] : nil
            item.trailingDetail = optionTrailingDetails.indices.contains(i) ? optionTrailingDetails[i] : nil
            item.isDisabled = disabledOptions.contains(i)
            optionAt[items.count] = i
            items.append(item)
        }
        let selectedRow = selectedIndex.flatMap { s in optionAt.first { $0.value == s }?.key }
        let list = MenuPopupView(items: items, style: .select)
        list.minimumWidth = bounds.width
        list.onChoose = { [weak self] row in
            guard let i = optionAt[row] else { return }
            self?.selectedIndex = i
            self?.onChange?(i)
        }
        var placement = PopupPlacement.dropdown
        if !alignItemWithTrigger { placement.align = popupAlign; placement.side = popupSide }
        let popup = host.open(list, trigger: self, placement: placement, swallowsOutsideClick: true)
        list.hostPopup = popup
        list.highlightedIndex = selectedRow ?? (NSApp.currentEvent?.type == .keyDown ? list.selectable.first : nil)
        if alignItemWithTrigger, let frame = Self.alignedFrame(list: list, selected: selectedRow, trigger: host.convert(bounds, from: self),
                                                               textInset: 1 + size.metrics.padding, bounds: host.bounds) {
            popup.container.frame = frame
        }
        openList = list
    }

    /// `alignItemWithTrigger`: the selected row's text lands on the trigger's text. Items grow to the
    /// trigger width + 20 (`in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)]`). Returns nil
    /// when the list does not fit between base-ui's 10px margins; the caller keeps the plain dropdown frame.
    static func alignedFrame(list: MenuPopupView, selected: Int?, trigger: CGRect, textInset: CGFloat, bounds: CGRect) -> CGRect? {
        guard let selected else { return nil }
        list.minimumWidth = trigger.width + 20 + 2 * MenuPopupView.inset
        let size = list.intrinsicContentSize
        let rowTop = MenuPopupView.inset + CGFloat(selected) * 28
        let rowTextX = MenuPopupView.inset + 8
        var frame = CGRect(x: trigger.minX + textInset - rowTextX, y: trigger.midY - rowTop - 14, width: size.width, height: size.height)
        let inner = bounds.insetBy(dx: 10, dy: 10)
        guard frame.height <= inner.height else { list.minimumWidth = trigger.width; return nil }
        frame.origin.y = min(max(frame.minY, inner.minY), inner.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, bounds.minX + 5), bounds.maxX - 5 - frame.width)
        return frame
    }
}
