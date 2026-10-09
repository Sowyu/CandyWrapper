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
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.popUpButton)
        updateValue()
    }

    private func updateValue() {
        label.text = selectedIndex.map { options[$0] } ?? placeholder
        restyle()
    }

    /// `w-full min-w-36`: the trigger fills its container, so it has no intrinsic width.
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: size.metrics.height) }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let m = size.metrics
        let chevronX = bounds.width - 1 - m.padding + 4 - 12
        chevron.frame = NSRect(x: chevronX, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.frame = NSRect(x: 1 + m.padding, y: (bounds.height - m.line) / 2, width: max(0, chevronX - m.gap - 1 - m.padding), height: m.line)
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
        box.radius = m.radius
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
        chevron.alphaValue = 0.5
        decoration.boxStyle = box
        needsLayout = true
    }

    // MARK: Popup

    public override func performAction() {
        super.performAction()
        guard let host = popupHost else { return }
        let items = options.enumerated().map { i, title in MenuItem(title, kind: .radio(i == selectedIndex)) }
        let list = MenuPopupView(items: items, style: .select)
        list.minimumWidth = bounds.width
        list.onChoose = { [weak self] i in
            self?.selectedIndex = i
            self?.onChange?(i)
        }
        let popup = host.open(list, trigger: self, placement: .dropdown, swallowsOutsideClick: true)
        list.hostPopup = popup
        list.highlightedIndex = selectedIndex ?? (NSApp.currentEvent?.type == .keyDown ? list.selectable.first : nil)
        if let frame = Self.alignedFrame(list: list, selected: selectedIndex, trigger: host.convert(bounds, from: self),
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
