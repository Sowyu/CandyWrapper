import AppKit
import DesignSystem
import T3Store

/// The thread's terminal drawer under the chat column (ThreadTerminalDrawer.tsx:1494-1700): an
/// `aside` with `border-t border-border/80 bg-background`, a 6pt drag handle along its top edge,
/// the terminal filling it, and the action cluster floating at its top right. Without terminals it
/// shows T3's empty state instead.
@MainActor
public final class TerminalDrawerView: DSView {
    /// The drag handle (`h-1.5`).
    static let handleHeight: CGFloat = 6

    public let actions = TerminalActionCluster()
    private let border = CALayer()
    private let handle = ResizeHandle()
    private let emptyLabel = LabelView("No terminal sessions for this thread yet.", font: DSFont.ui(14))
    public let emptyButton = ButtonView("New Terminal", variant: .outline, size: .xs)

    /// The live terminal, owned by the controller; nil shows the empty state.
    public var surface: TerminalSurfaceView? {
        didSet {
            guard surface !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let surface { addSubview(surface, positioned: .below, relativeTo: actions) }
            emptyLabel.isHidden = surface != nil
            emptyButton.isHidden = surface != nil
            actions.isHidden = surface == nil
            needsLayout = true
        }
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
        addSubview(emptyButton)
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
        border.frame = CGRect(x: 0, y: 0, width: w, height: 1)
        handle.frame = NSRect(x: 0, y: 0, width: w, height: Self.handleHeight)
        let content = NSRect(x: 0, y: 1, width: w, height: max(0, h - 1))
        surface?.frame = content
        let size = actions.intrinsicContentSize
        // `absolute right-2 top-2`, from the aside's border box.
        actions.frame = NSRect(x: w - 8 - size.width, y: 8, width: size.width, height: size.height)
        // Empty state: `flex-col items-center justify-center gap-3 px-4 py-6 text-sm`.
        let labelHeight: CGFloat = 20, buttonHeight = emptyButton.intrinsicContentSize.height
        let block = labelHeight + 12 + buttonHeight
        let top = (1 + (h - 1 - block) / 2).rounded()
        emptyLabel.frame = NSRect(x: 16, y: top, width: max(0, w - 32), height: labelHeight)
        let bw = emptyButton.intrinsicContentSize.width
        emptyButton.frame = NSRect(x: ((w - bw) / 2).rounded(), y: top + labelHeight + 12, width: bw, height: buttonHeight)
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        border.backgroundColor = Themed.color(\.border, 0.8).cgColor(in: self)
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
    public override var intrinsicContentSize: NSSize { NSSize(width: 2 + 4 * 21 + 3, height: 2 + 21) }

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
        style.radius = 8
        style.fill = Themed.color(\.background)
        style.border = Themed.color(\.border, 0.8)
        // `shadow-xs`: 0 1px 2px rgb(0 0 0 / 5%).
        style.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
        box.boxStyle = style
        box.setNeedsDisplay()
        for rule in rules { rule.backgroundColor = Themed.color(\.border, 0.8).cgColor(in: self) }
    }

    /// One `p-1 text-foreground/90 hover:bg-accent` button. The cluster clips them to its corners.
    final class Button: ControlView {
        private let icon: IconView
        var limited = false { didSet { alphaValue = limited ? 0.64 : 1; needsDisplay = true } }

        init(icon name: IconName) {
            icon = IconView(name: name, size: 13)
            super.init(frame: .zero)
            scalesWhenPressed = false
            addSubview(icon)
        }

        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 4, y: 4, width: 13, height: 13)
        }

        override func updateLayer() {
            icon.strokeColor = Themed.color(\.foreground, 0.9)
            let fill: NSColor? = state.hovered && !limited ? Themed.color(\.accent) : nil
            layer?.backgroundColor = fill?.cgColor(in: self)
        }
    }
}
