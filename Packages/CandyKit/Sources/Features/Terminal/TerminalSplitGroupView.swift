import AppKit
import DesignSystem
import T3Store

/// The active group's terminals (ThreadTerminalDrawer.tsx:1600-1660): a grid of equal columns
/// (side by side) or rows (stacked) with no gap. Every pane after the first has a 1pt leading or
/// top border, `border-border` on the active pane and `border-border/70` on the others. One pane
/// fills the area with no border. The controller owns the surfaces and creates them only while
/// they show.
@MainActor
public final class TerminalSplitGroupView: DSView {
    public private(set) var paneIds: [String] = []
    private var cells: [Cell] = []
    public private(set) var direction: TerminalGroup.Direction = .horizontal
    public private(set) var activeId = ""

    /// Puts `panes` in the grid. Surfaces that left are removed from the view tree.
    public func show(_ panes: [(id: String, surface: TerminalSurfaceView)], direction: TerminalGroup.Direction, activeId: String) {
        let kept = Set(panes.map { ObjectIdentifier($0.surface) })
        for cell in cells where !kept.contains(ObjectIdentifier(cell.surface)) {
            cell.surface.removeFromSuperview()
            cell.removeFromSuperview()
        }
        let old = Dictionary(cells.map { (ObjectIdentifier($0.surface), $0) }) { a, _ in a }
        cells = panes.map { pane in
            if let cell = old[ObjectIdentifier(pane.surface)] { return cell }
            let cell = Cell(surface: pane.surface)
            addSubview(cell)
            return cell
        }
        paneIds = panes.map(\.id)
        self.direction = direction
        self.activeId = activeId
        let split = panes.count > 1
        for (i, cell) in cells.enumerated() {
            cell.edge = !split || i == 0 ? nil : direction
            cell.isActive = paneIds[i] == activeId
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let n = CGFloat(max(1, cells.count))
        for (i, cell) in cells.enumerated() {
            let f = CGFloat(i)
            if direction == .vertical {
                let y0 = (bounds.height * f / n).rounded(), y1 = (bounds.height * (f + 1) / n).rounded()
                cell.frame = NSRect(x: 0, y: y0, width: bounds.width, height: y1 - y0)
            } else {
                let x0 = (bounds.width * f / n).rounded(), x1 = (bounds.width * (f + 1) / n).rounded()
                cell.frame = NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height)
            }
        }
    }

    /// One `min-h-0 min-w-0` grid cell with its `border-l`/`border-t`.
    final class Cell: DSView {
        let surface: TerminalSurfaceView
        private let rule = CALayer()
        /// The border's side: nil for the first pane (or a single one).
        var edge: TerminalGroup.Direction? { didSet { if edge != oldValue { needsLayout = true; needsDisplay = true } } }
        var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }

        init(surface: TerminalSurfaceView) {
            self.surface = surface
            super.init(frame: .zero)
            rule.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(rule)
            addSubview(surface)
            clipsToBounds = true
        }

        override func layout() {
            super.layout()
            switch edge {
            case .horizontal?:
                rule.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
                surface.frame = NSRect(x: 1, y: 0, width: max(0, bounds.width - 1), height: bounds.height)
            case .vertical?:
                rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
                surface.frame = NSRect(x: 0, y: 1, width: bounds.width, height: max(0, bounds.height - 1))
            case nil:
                rule.frame = .zero
                surface.frame = bounds
            }
        }

        override func updateLayer() {
            rule.backgroundColor = Themed.color(\.border, isActive ? 1 : 0.7).cgColor(in: self)
        }
    }
}

/// What the terminal list shows (ThreadTerminalDrawer.tsx:1748-1830).
public struct TerminalListModel: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var id: String
        public var label: String
        public var isActive: Bool
        /// "Close Terminal 2", with the shortcut on the active row.
        public var closeLabel: String
    }
    public struct Group: Equatable, Sendable {
        public var id: String
        /// "Single", "Side by side" or "Stacked".
        public var label: String
        public var icon: IconName
        public var isActive: Bool
        /// The terminal a click on the header activates.
        public var target: String
        public var rows: [Row]
    }
    public var groups: [Group]
    public var showHeaders: Bool

    public init(groups: [Group], showHeaders: Bool) { self.groups = groups; self.showHeaders = showHeaders }

    /// The list for `state`'s groups, with `label` naming each terminal.
    public static func make(_ state: TerminalDrawerState, label: (String) -> String, closeShortcut: String?) -> TerminalListModel {
        let active = state.resolvedActiveId ?? ""
        let groups = state.resolvedGroups.map { group -> Group in
            let isActive = group.terminalIds.contains(active)
            let split = group.terminalIds.count > 1
            let rows = group.terminalIds.map { id -> Row in
                let name = label(id)
                let shortcut = id == active ? closeShortcut.map { " (\($0))" } ?? "" : ""
                return Row(id: id, label: name, isActive: id == active, closeLabel: "Close \(name)\(shortcut)")
            }
            return Group(id: group.id,
                         label: !split ? "Single" : group.splitDirection == .vertical ? "Stacked" : "Side by side",
                         icon: !split ? .square : group.splitDirection == .vertical ? .squareSplitVertical : .squareSplitHorizontal,
                         isActive: isActive, target: isActive ? active : (group.terminalIds.first ?? active), rows: rows)
        }
        return TerminalListModel(groups: groups, showHeaders: state.showGroupHeaders)
    }
}

/// The terminal list beside the panes once a thread has two or more terminals
/// (ThreadTerminalDrawer.tsx:1700-1830): `w-36 border border-border/70 bg-muted/10`, a 22pt header
/// with the four actions (the floating cluster hides), then the groups with optional headers and
/// one `h-6` row per terminal whose glyph turns into a close button on hover.
@MainActor
public final class TerminalListAsideView: DSView {
    public static let width: CGFloat = 144

    private let box = BoxDecorationLayer()
    private let headerRule = CALayer()
    private var buttons: [TerminalActionCluster.Action: HeaderButton] = [:]
    private var headerRules: [CALayer] = []
    private let scroll = NSScrollView()
    private let content = FlippedContent()
    private var model = TerminalListModel(groups: [], showHeaders: false)

    public var onAction: ((TerminalActionCluster.Action) -> Void)?
    public var onActivate: ((String) -> Void)?
    public var onClose: ((String) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        box.host = self
        layer?.addSublayer(box)
        for layer in [headerRule] + (0..<3).map({ _ in CALayer() }) {
            layer.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            self.layer?.addSublayer(layer)
            if layer !== headerRule { headerRules.append(layer) }
        }
        for action in TerminalActionCluster.Action.allCases {
            let icon: IconName = switch action {
            case .split: .squareSplitHorizontal
            case .splitVertical: .squareSplitVertical
            case .new: .plus
            case .close: .trash2
            }
            let button = HeaderButton(icon: icon)
            button.action = { [weak self] in self?.onAction?(action) }
            buttons[action] = button
            addSubview(button)
        }
        scroll.drawsBackground = false
        scroll.useT3Scrollbars(.native) // `overflow-y-auto` (ThreadTerminalDrawer.tsx:1747)
        scroll.documentView = content
        addSubview(scroll)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminals")
    }

    public func setLabels(split: String, splitVertical: String, new: String, close: String) {
        for (action, text) in [(TerminalActionCluster.Action.split, split), (.splitVertical, splitVertical), (.new, new), (.close, close)] {
            guard let button = buttons[action] else { continue }
            button.setAccessibilityLabel(text)
            button.tooltip = TooltipController.attach(to: button, text: text, placement: PopupPlacement(side: .bottom, align: .center, sideOffset: 6))
        }
    }

    public func setSplitLimitReached(_ reached: Bool) {
        for action in [TerminalActionCluster.Action.split, .splitVertical] { buttons[action]?.limited = reached }
    }

    public func apply(_ model: TerminalListModel) {
        guard model != self.model || content.subviews.isEmpty else { return }
        self.model = model
        content.subviews.forEach { $0.removeFromSuperview() }
        for group in model.groups {
            if model.showHeaders {
                let header = GroupHeader(group)
                header.action = { [weak self] in self?.onActivate?(group.target) }
                content.addSubview(header)
            }
            for row in group.rows {
                let view = Row(row)
                view.onSelect = { [weak self] in self?.onActivate?(row.id) }
                view.close.action = { [weak self] in self?.onClose?(row.id) }
                content.addSubview(view)
            }
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        box.frame = bounds.insetBy(dx: -box.outset, dy: -box.outset)
        // Header: `h-[22px] border-b`, buttons flush right inside the 1pt border.
        headerRule.frame = CGRect(x: 1, y: 1 + 22, width: max(0, bounds.width - 2), height: 1)
        var x = bounds.width - 1
        let order = TerminalActionCluster.Action.allCases.reversed()
        for (i, action) in order.enumerated() {
            x -= 21
            buttons[action]?.frame = NSRect(x: x, y: 1, width: 21, height: 22)
            // `border-l` on every button but the first.
            if i < 3 { x -= 1; headerRules[i].frame = CGRect(x: x, y: 1, width: 1, height: 22) }
        }
        CATransaction.commit()
        let top: CGFloat = 1 + 22 + 1
        scroll.frame = NSRect(x: 1, y: top, width: max(0, bounds.width - 2), height: max(0, bounds.height - top - 1))
        // `px-1 py-1`; groups `pb-0.5`, rows `gap-0.5`.
        let w = scroll.frame.width - 8
        var y: CGFloat = 4
        var lastGroupEnd = false
        for view in content.subviews {
            if let header = view as? GroupHeader {
                if lastGroupEnd { y += 2 }
                header.frame = NSRect(x: 4, y: y, width: w, height: 22)
                y += 22
                lastGroupEnd = false
            } else if let row = view as? Row {
                row.frame = NSRect(x: 4, y: y, width: w, height: 24)
                y += 24 + 2
                lastGroupEnd = true
            }
        }
        // An overflowing list gives the scrollbar its 6px lane.
        let lane: CGFloat = y + 4 > scroll.frame.height ? ScrollAreaScroller.laneWidth : 0
        if lane > 0 { for view in content.subviews where view is GroupHeader || view is Row { view.frame.size.width -= lane } }
        content.frame = NSRect(x: 0, y: 0, width: scroll.frame.width - lane, height: max(scroll.frame.height, y + 4))
    }

    public override func updateLayer() {
        var style = BoxStyle()
        style.fill = Themed.color(\.muted, 0.1)
        style.border = Themed.color(\.border, 0.7)
        box.boxStyle = style
        box.setNeedsDisplay()
        let rule = Themed.color(\.border, 0.7).cgColor(in: self)
        headerRule.backgroundColor = rule
        for r in headerRules { r.backgroundColor = rule }
    }

    final class FlippedContent: NSView { override var isFlipped: Bool { true } }

    /// `inline-flex h-full items-center px-1 text-foreground/90 hover:bg-accent/70`.
    final class HeaderButton: ControlView {
        private let icon: IconView
        var tooltip: TooltipController?
        var limited = false { didSet { alphaValue = limited ? 0.64 : 1; needsDisplay = true } }

        init(icon name: IconName) {
            icon = IconView(name: name, size: 13)
            super.init(frame: .zero)
            scalesWhenPressed = false
            transitions = .colors // transition-colors (ThreadTerminalDrawer.tsx:1706-1738)
            addSubview(icon)
        }

        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 4, y: ((bounds.height - 13) / 2).rounded(), width: 13, height: 13)
        }

        override func updateLayer() {
            icon.strokeColor = Themed.color(\.foreground, 0.9)
            Motion.setBackground(layer, state.hovered && !limited ? Themed.color(\.accent, 0.7).cgColor(in: self) : nil)
        }
    }

    /// `flex h-[22px] items-center gap-1 rounded px-1.5 text-2xs`, a 12pt group glyph, the label and
    /// the count (`text-3xs tabular-nums text-muted-foreground/70`).
    final class GroupHeader: ControlView {
        private let icon: IconView
        private let label: LabelView
        private let count: LabelView
        private let active: Bool

        init(_ group: TerminalListModel.Group) {
            active = group.isActive
            icon = IconView(name: group.icon, size: 12)
            label = LabelView(group.label, font: DSFont.ui(11))
            count = LabelView("\(group.rows.count)", font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular))
            super.init(frame: .zero)
            scalesWhenPressed = false
            layer?.cornerRadius = 4
            [icon, label, count].forEach(addSubview)
            setAccessibilityRole(.button)
            setAccessibilityLabel(group.label)
        }

        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 6, y: 5, width: 12, height: 12)
            let cw = ceil(count.textWidth)
            count.frame = NSRect(x: bounds.width - 6 - cw, y: 4, width: cw, height: 14)
            label.frame = NSRect(x: 22, y: 3, width: max(0, count.frame.minX - 4 - 22), height: 16)
        }

        override func updateLayer() {
            let fg = Themed.color(active || state.hovered ? \.foreground : \.mutedForeground)
            icon.strokeColor = fg
            label.color = fg
            count.color = Themed.color(\.mutedForeground, 0.7)
            let fill: NSColor? = active ? Themed.color(\.accent, 0.5) : state.hovered ? Themed.color(\.accent, 0.4) : nil
            layer?.backgroundColor = fill?.cgColor(in: self)
        }
    }

    /// `group/tab flex h-6 items-center gap-0.5 rounded-md pr-2 pl-1.5 text-xs`: the terminal glyph
    /// as a close button, then the label.
    final class Row: DSView {
        let close: PanelTabCloseButton
        private let glyph: IconView
        private let label: LabelView
        private let active: Bool
        private var hovered = false { didSet { if hovered != oldValue { close.isTabHovered = hovered; needsDisplay = true } } }
        private var tracking: NSTrackingArea?
        var onSelect: (() -> Void)?

        init(_ row: TerminalListModel.Row) {
            active = row.isActive
            let glyph = IconView(name: .terminalSquare, size: 12)
            self.glyph = glyph
            close = PanelTabCloseButton(identity: glyph, label: row.closeLabel)
            label = LabelView(row.label, font: DSFont.ui(12))
            super.init(frame: .zero)
            label.lineHeight = 16
            layer?.cornerRadius = 8
            addSubview(close)
            addSubview(label)
            TooltipController.attach(to: close, text: row.closeLabel)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(row.label)
        }

        override func layout() {
            super.layout()
            close.frame = NSRect(x: 6, y: 4, width: 16, height: 16)
            label.frame = NSRect(x: 24, y: 4, width: max(0, bounds.width - 24 - 8), height: 16)
        }

        override func updateLayer() {
            layer?.cornerRadius = DesignGeometry.radius(8, in: self)
            let fg = Themed.color(active || hovered ? \.foreground : \.mutedForeground)
            label.color = fg
            glyph.strokeColor = fg
            let fill: NSColor? = active ? Themed.color(\.accent) : hovered ? Themed.color(\.accent, 0.6) : nil
            layer?.backgroundColor = fill?.cgColor(in: self)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func mouseDown(with event: NSEvent) { onSelect?() }
    }
}
