import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Redesign's "when" button on Settled's header (in the list beside the chevron, in the shelf's popover in its header):
/// the current range in the muted 12pt with a small chevron, which opens `SettledRangePickerView`.
final class SettledRangeButton: ControlView {
    private let label = LabelView()
    private let chevron = IconView(name: .chevronDown, size: 12)
    private let fill = CALayer()

    var range = SettledRange.any {
        didSet {
            guard range != oldValue else { return }
            label.text = range.title
            setAccessibilityValue(range.title)
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fill.cornerRadius = RedesignTokens.Radius.control
        layer?.addSublayer(fill)
        label.text = range.title
        label.font = SB.font(12)
        label.lineHeight = 16
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Settled when")
        setAccessibilityValue(range.title)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 6 + ceil(label.textWidth) + 2 + 12 + 4, height: 20) }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func updateLayer() { restyle() }

    private func restyle() {
        let ink = state.hoverOrPressed ? SB.c(\.sidebarForeground) : SB.c(\.sidebarMutedForeground)
        label.color = ink
        chevron.strokeColor = ink
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = RedesignTokens.State.fill(state, dark: effectiveAppearance.isDark)?.cgColor(in: self)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = bounds
        CATransaction.commit()
        let w = ceil(label.textWidth)
        label.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: w, height: 16)
        chevron.frame = NSRect(x: label.frame.maxX + 2, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }
}

/// The "when" list, in the project filter popover's frame and rows (`PickerPopupView`, `ScopeRowView`) with a check on
/// the current choice.
final class SettledRangePickerView: DSView, PickerPopupBody {
    static let rowHeight: CGFloat = 28, padding: CGFloat = 4
    let current: SettledRange
    private(set) var rows: [ScopeRowView] = []
    private(set) var highlighted: Int? { didSet { if highlighted != oldValue { rows.forEach { $0.restyle() } } } }
    var onSelect: (@MainActor (SettledRange) -> Void)?

    init(current: SettledRange) {
        self.current = current
        super.init(frame: .zero)
        for (i, range) in SettledRange.allCases.enumerated() {
            let row = ScopeRowView(item: .init(key: range.rawValue, label: range.title), selected: range == current, extra: .addProject,
                                   icon: range == .any ? .history : .clock)
            row.isHighlighted = { [weak self] in self?.highlighted == i }
            row.onHover = { [weak self] in self?.highlighted = i }
            row.action = { [weak self] in self?.onSelect?(range) }
            rows.append(row)
            addSubview(row)
        }
        highlighted = SettledRange.allCases.firstIndex(of: current)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Settled when")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var naturalSize: CGSize {
        let widest = rows.map(\.naturalWidth).max() ?? 0
        return CGSize(width: max(180, ceil(widest) + 8 + 24), height: CGFloat(rows.count) * Self.rowHeight + 2 * Self.padding)
    }

    func handleKey(_ key: PopupKey) -> Bool {
        let n = rows.count
        switch key {
        case .down: highlighted = ((highlighted ?? -1) + 1) % n; return true
        case .up: highlighted = ((highlighted ?? n) - 1 + n) % n; return true
        case .home: highlighted = 0; return true
        case .end: highlighted = n - 1; return true
        case .enter, .space:
            if let h = highlighted { onSelect?(SettledRange.allCases[h]) }
            return true
        default: return false
        }
    }

    override func layout() {
        super.layout()
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: Self.padding, y: Self.padding + CGFloat(i) * Self.rowHeight, width: bounds.width - 2 * Self.padding,
                               height: Self.rowHeight)
        }
    }
}

/// Settled filtered to a range with nothing in it: Redesign's state view at its inline size, with Show any time.
final class SidebarSettledEmptyRowView: SidebarRowBase {
    private let notice = EmptyView(title: "", size: .inline)
    var onShowAnyTime: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(notice)
        notice.action = StateAction("Show any time") { [weak self] in self?.onShowAnyTime?() }
    }

    override func refresh() {
        guard case .settledEmpty(let range)? = item else { return }
        notice.redesign = StateCopy(title: range.emptyTitle)
        setAccessibilityLabel(range.emptyText)
        needsLayout = true
    }

    override func performAction() { onShowAnyTime?() }

    override func layout() {
        super.layout()
        let h = min(bounds.height, notice.height(forWidth: bounds.width))
        notice.frame = NSRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h)
    }
}
