import AppKit
import DesignSystem
import T3Store

/// The thread's terminal drawer under the chat column (ThreadTerminalDrawer.tsx:1494-1830): an
/// `aside` with `border-t border-border/80 bg-background`, a 6pt drag handle along its top edge,
/// the active group's terminals filling it, and the action cluster floating at its top right. With
/// two or more terminals the list aside sits at the right (`gap-1.5`) and carries the actions
/// instead. Without terminals it shows T3's empty state. In a right panel tab (`mode="panel"`) it
/// has no top border and no handle.
///
/// Redesign draws it as a card (`isCard`) inset from the thread and the window like the right panel: rounded, clipped,
/// with a rim and no top border. Its height handle then lives in the gap above it, in the thread panel.
@MainActor
public final class TerminalDrawerView: DSView {
    /// The drag handle (`h-1.5`).
    static let handleHeight: CGFloat = 6

    public let actions = TerminalActionCluster()
    public let grid = TerminalSplitGroupView()
    public let list = TerminalListAsideView()
    private let border = CALayer()
    private let handle = ResizeHandle()
    private let emptyLabel = LabelView("No terminal sessions for this thread yet.", font: DSFont.ui(14))
    public let emptyButton = ButtonView("New Terminal", variant: .outline, size: .xs)
    /// Redesign's empty state in place of T3's label and button; its action is `emptyButton`'s.
    let emptyState = EmptyView(title: "", size: .default)

    /// A right panel tab's terminal: no top border, no height handle.
    public var isPanel = false {
        didSet { syncChrome() }
    }

    /// Redesign's inset card: rounded corners that clip the terminals, the rim, no top border and no handle of its own.
    /// The actions sit in a compact row at the card's top right, over the list when it shows.
    public var isCard = false {
        didSet { guard isCard != oldValue else { return }; syncChrome(); needsDisplay = true }
    }

    /// The keyboard is in one of the drawer's terminals; the card's rim takes the accent.
    public private(set) var hasKeyFocus = false {
        didSet { if hasKeyFocus != oldValue { needsDisplay = true } }
    }
    private var responderObservation: NSKeyValueObservation?

    private func syncChrome() {
        handle.isHidden = isPanel || isCard
        border.isHidden = isPanel || isCard
        actions.isCard = isCard
        list.isCard = isCard
        actions.isHidden = panes.isEmpty || (listShown && !isCard)
        needsLayout = true
    }

    /// The panes on screen; empty shows the empty state.
    public private(set) var panes: [(id: String, surface: TerminalSurfaceView)] = []
    private var listShown = false

    /// One terminal and no list (the drawer before splits existed, and the fidelity test).
    public var surface: TerminalSurfaceView? {
        get { panes.first?.surface }
        set { show(newValue.map { [(id: "", surface: $0)] } ?? [], direction: .horizontal, activeId: "", list: nil) }
    }

    /// Shows the active group's `panes` and, with two or more terminals, the list.
    public func show(_ panes: [(id: String, surface: TerminalSurfaceView)], direction: TerminalGroup.Direction, activeId: String,
                     list model: TerminalListModel?) {
        self.panes = panes
        grid.show(panes, direction: direction, activeId: activeId)
        let empty = panes.isEmpty
        grid.isHidden = empty
        syncEmpty()
        listShown = !empty && model != nil
        if let model { list.apply(model) }
        list.isHidden = !listShown
        actions.isHidden = empty || (listShown && !isCard)
        needsLayout = true
    }

    /// Height drag: the start height plus how far the pointer moved up. `ended` once on release.
    public var onDrag: ((_ startHeight: CGFloat, _ deltaUp: CGFloat, _ ended: Bool) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        border.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(border)
        emptyLabel.alignment = .center
        emptyLabel.lineHeight = 20
        addSubview(emptyLabel)
        addSubview(emptyState)
        emptyState.isHidden = true
        addSubview(emptyButton)
        grid.isHidden = true
        addSubview(grid)
        list.isHidden = true
        addSubview(list)
        actions.isHidden = true
        addSubview(actions)
        addSubview(handle)
        handle.onDrag = { [weak self] delta, ended in
            guard let self else { return }
            if handle.startHeight == nil { handle.startHeight = bounds.height }
            onDrag?(handle.startHeight ?? bounds.height, delta, ended)
            if ended { handle.startHeight = nil }
        }
        clipsToBounds = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal")
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let top: CGFloat = isPanel || isCard ? 0 : 1
        border.frame = CGRect(x: 0, y: 0, width: w, height: 1)
        handle.frame = NSRect(x: 0, y: 0, width: w, height: Self.handleHeight)
        let content = NSRect(x: 0, y: top, width: w, height: max(0, h - top))
        if listShown {
            let listWidth = TerminalListAsideView.width
            list.frame = NSRect(x: content.maxX - listWidth, y: content.minY, width: listWidth, height: content.height)
            // The card keeps one surface: the list meets the terminals on a hairline, with no gap.
            grid.frame = NSRect(x: 0, y: content.minY, width: max(0, content.width - listWidth - (isCard ? 0 : 6)), height: content.height)
        } else {
            grid.frame = content
        }
        let size = actions.intrinsicContentSize
        if isCard {
            // The card's top row, like the right panel's: 24pt controls 4pt in from the top and right.
            let row = CardTopRow(width: w, pill: .zero, trailing: [size])
            actions.frame = row.trailing[0]
        } else {
            // `absolute right-2 top-2`, from the aside's border box.
            actions.frame = NSRect(x: w - 8 - size.width, y: 8, width: size.width, height: size.height)
        }
        // Empty state: `flex-col items-center justify-center gap-3 px-4 py-6 text-sm`.
        let labelHeight: CGFloat = 20, buttonHeight = emptyButton.intrinsicContentSize.height
        let block = labelHeight + 12 + buttonHeight
        let emptyTop = (top + (h - top - block) / 2).rounded()
        emptyLabel.frame = NSRect(x: 16, y: emptyTop, width: max(0, w - 32), height: labelHeight)
        let bw = emptyButton.intrinsicContentSize.width
        emptyButton.frame = NSRect(x: ((w - bw) / 2).rounded(), y: emptyTop + labelHeight + 12, width: bw, height: buttonHeight)
        emptyState.frame = NSRect(x: 0, y: top, width: w, height: max(0, h - top))
    }

    private func syncEmpty() {
        let empty = panes.isEmpty, redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        emptyLabel.isHidden = !empty || redesign
        emptyButton.isHidden = !empty || redesign
        emptyState.isHidden = !empty || !redesign
        if redesign, emptyState.redesign == nil {
            emptyState.redesign = StateCopy(title: "No terminals yet", detail: "Open a shell in this thread's folder.", icon: .terminal)
            emptyState.action = StateAction("New terminal", icon: .plus) { [weak self] in self?.emptyButton.action?() }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncEmpty()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncEmpty()
        // The first responder lives deep in SwiftTerm, whose focus methods this module cannot override; the window
        // reports every change instead. Only the card shows focus.
        responderObservation = window.map { window in
            window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncKeyFocus() }
            }
        }
        syncKeyFocus()
    }

    func syncKeyFocus() {
        hasKeyFocus = isCard && !panes.isEmpty && (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
    }

    public override func updateLayer() {
        // The split container is `bg-(--terminal-background)`, the app's background.
        layer?.backgroundColor = WindowGlass.pick(stock: Themed.color(\.background), frost: WindowGlass.denseFill).cgColor(in: self)
        border.backgroundColor = Themed.color(\.border, 0.8).cgColor(in: self)
        if let layer {
            layer.cornerRadius = isCard ? RedesignTokens.Radius.panel : 0
            layer.cornerCurve = .continuous
            layer.borderWidth = isCard ? 1 : 0
            let dark = effectiveAppearance.isDark
            // Focus shows quietly: the rim takes the accent at low strength instead of the text color.
            layer.borderColor = !isCard ? nil : hasKeyFocus ? Themed.color(\.primary, RedesignTokens.Surface.focusRim).cgColor(in: self)
                : RedesignTokens.Surface.rim(dark: dark).cgColor
        }
        emptyLabel.color = Themed.color(\.mutedForeground)
    }

    /// The drag strip: row-resize cursor, reports the pointer's travel upward.
    final class ResizeHandle: NSView {
        var onDrag: ((CGFloat, Bool) -> Void)?
        var startHeight: CGFloat?
        private var startY: CGFloat = 0
        private var moved = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

        override func mouseDown(with event: NSEvent) {
            startY = NSEvent.mouseLocation.y
            startHeight = nil
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            moved = true
            onDrag?(NSEvent.mouseLocation.y - startY, false)
        }

        override func mouseUp(with event: NSEvent) {
            if moved { onDrag?(NSEvent.mouseLocation.y - startY, true) }
            startHeight = nil
        }
    }
}

/// The floating cluster (ThreadTerminalDrawer.tsx:1553-1600): `inline-flex rounded-md border
/// border-border/80 bg-background shadow-xs`, four `p-1` buttons with 13pt icons divided by
/// `h-4 w-px bg-border/80` rules. Each button's label shows as a tooltip below it.
@MainActor
public final class TerminalActionCluster: DSView {
    public enum Action: CaseIterable { case split, splitVertical, new, close }

    private let box = BoxDecorationLayer()
    private var buttons: [Action: Button] = [:]
    private var tooltips: [Action: TooltipController] = [:]
    private let rules = (0..<3).map { _ in CALayer() }
    public var onAction: ((Action) -> Void)?
    /// Redesign's card row: 24pt buttons at the control corner, 2pt apart, with no border, rules or shadow.
    var isCard = false {
        didSet {
            guard isCard != oldValue else { return }
            for (action, button) in buttons {
                button.isCard = isCard
                let end = action == .split || action == .close
                button.layer?.cornerRadius = isCard ? RedesignTokens.Radius.control : end ? 7 : 0
                button.layer?.cornerCurve = .continuous
                button.layer?.maskedCorners = isCard ? [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
                    : action == .split ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
                    : action == .close ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : button.layer?.maskedCorners ?? []
            }
            for rule in rules { rule.isHidden = isCard }
            invalidateIntrinsicContentSize()
            needsLayout = true
            needsDisplay = true
        }
    }
    static let cardButton: CGFloat = 24
    static let cardSpacing: CGFloat = 2

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        box.host = self
        layer?.addSublayer(box)
        for rule in rules {
            rule.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(rule)
        }
        for action in Action.allCases {
            let icon: IconName = switch action {
            case .split: .squareSplitHorizontal
            case .splitVertical: .squareSplitVertical
            case .new: .plus
            case .close: .trash2
            }
            let button = Button(icon: icon)
            button.action = { [weak self] in self?.onAction?(action) }
            // The cluster is `overflow-hidden`: the end buttons' hover fill follows its inner corners.
            if action == .split { button.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner] }
            if action == .close { button.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] }
            if action == .split || action == .close { button.layer?.cornerRadius = 7 }
            buttons[action] = button
            addSubview(button)
        }
        setLabels(split: "Split Terminal Horizontally", splitVertical: "Split Terminal Vertically", new: "New Terminal", close: "Close Terminal")
    }

    /// `p-1` around `size-3.25`: 21pt square buttons, three 1pt rules, a 1pt border all round.
    public override var intrinsicContentSize: NSSize {
        if isCard {
            let n = CGFloat(Action.allCases.count)
            return NSSize(width: n * Self.cardButton + (n - 1) * Self.cardSpacing, height: Self.cardButton)
        }
        return NSSize(width: 2 + 4 * 21 + 3, height: 2 + 21)
    }

    /// The tooltip texts (`splitTerminalActionLabel` and friends, with shortcut labels).
    public func setLabels(split: String, splitVertical: String, new: String, close: String) {
        for (action, text) in [(Action.split, split), (.splitVertical, splitVertical), (.new, new), (.close, close)] {
            guard let button = buttons[action] else { continue }
            button.setAccessibilityLabel(text)
            tooltips[action] = TooltipController.attach(to: button, text: text,
                                                  placement: PopupPlacement(side: .bottom, align: .center, sideOffset: 6))
        }
    }

    /// `hasReachedSplitLimit`: the split buttons dim (`opacity-64`) and stop reacting to hover.
    public func setSplitLimitReached(_ reached: Bool) {
        for action in [Action.split, .splitVertical] { buttons[action]?.limited = reached }
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        box.frame = bounds.insetBy(dx: -box.outset, dy: -box.outset)
        if isCard {
            for (i, action) in Action.allCases.enumerated() {
                let x = CGFloat(i) * (Self.cardButton + Self.cardSpacing)
                buttons[action]?.frame = NSRect(x: x, y: 0, width: Self.cardButton, height: Self.cardButton)
            }
            CATransaction.commit()
            return
        }
        var x: CGFloat = 1
        for (i, action) in Action.allCases.enumerated() {
            buttons[action]?.frame = NSRect(x: x, y: 1, width: 21, height: 21)
            x += 21
            if i < rules.count {
                rules[i].frame = CGRect(x: x, y: 1 + (21 - 16) / 2, width: 1, height: 16)
                x += 1
            }
        }
        CATransaction.commit()
    }

    public override func updateLayer() {
        var style = BoxStyle()
        if isCard {
            // The card's own fill behind the buttons, so terminal text under the row never shows through them.
            style.radius = RedesignTokens.Radius.control
            style.fill = WindowGlass.pick(stock: Themed.color(\.background), frost: WindowGlass.denseFill)
        } else {
            style.radius = DesignGeometry.radius(8, in: self)
            style.fill = WindowGlass.paneFill
            style.border = Themed.color(\.border, 0.8)
            // `shadow-xs`: 0 1px 2px rgb(0 0 0 / 5%).
            style.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
        }
        box.boxStyle = style
        box.setNeedsDisplay()
        for rule in rules { rule.backgroundColor = Themed.color(\.border, 0.8).cgColor(in: self) }
    }

    /// One `p-1 text-foreground/90 hover:bg-accent` button. The cluster clips them to its corners.
    final class Button: ControlView {
        private let icon: IconView
        var limited = false { didSet { alphaValue = limited ? 0.64 : 1; needsDisplay = true } }
        var isCard = false { didSet { needsLayout = true } }

        init(icon name: IconName) {
            icon = IconView(name: name, size: 13)
            super.init(frame: .zero)
            scalesWhenPressed = false
            transitions = .colors // transition-colors (ThreadTerminalDrawer.tsx:1557-1592); theme changes snap
            addSubview(icon)
        }

        override func layout() {
            super.layout()
            let inset = ((bounds.width - 13) / 2).rounded(.down)
            icon.frame = NSRect(x: isCard ? inset : 4, y: isCard ? inset : 4, width: 13, height: 13)
        }

        override func updateLayer() {
            icon.strokeColor = Themed.color(\.foreground, 0.9)
            Motion.setBackground(layer, state.hovered && !limited ? Themed.color(\.accent).cgColor(in: self) : nil)
        }
    }
}
