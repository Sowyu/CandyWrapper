import AppKit
import DesignSystem
import T3Protocol

/// `BranchPicker` (BranchPicker.tsx:32-262): a `ComboboxPopup` with `ComboboxSearchInput` ("Search refs..."), the
/// ref list (`max-h-56`, `py-2 ps-1`, 28pt rows), "No refs found.", the "Start from remote" switch while a
/// new worktree's base is picked, and the paging status. The caller supplies the rows and acts on picks; the
/// query goes back through `onQuery` so the server filters (`vcs.listRefs` with `query`).
public final class BranchPickerView: DSView, PickerPopupBody {
    public struct Row: Equatable {
        /// The ref name, or a synthetic row's value (`__create_new_branch__:<query>`).
        public var value: String
        public var title: String
        public var badge: String?
        public var middleTruncates = true
        public var disabled = false
        public init(value: String, title: String, badge: String? = nil, middleTruncates: Bool = true, disabled: Bool = false) {
            self.value = value; self.title = title; self.badge = badge; self.middleTruncates = middleTruncates; self.disabled = disabled
        }
    }

    static let searchHeight: CGFloat = 43, rowHeight: CGFloat = 28, maxListHeight: CGFloat = 224
    /// `ComboboxList`'s `not-empty:px-1 not-empty:py-1` around LegendList's `ps-1 pe-0 py-2` and its 6px stable
    /// scrollbar gutter (BranchPicker.tsx:196-221, combobox.tsx): rows start 12 down and 8 in, and end 10 short of the
    /// right edge (measured in T3's web client: rows 8 to 308 of 318, list 76 tall with two rows). 3473 keeps 8px
    /// below the last row (#21159 05d60554ec, BranchPicker.tsx:213), so the list ends 12 below it.
    static let listTop: CGFloat = 12, listBottom: CGFloat = 12, rowLeft: CGFloat = 8, rowRight: CGFloat = 10

    public var rows: [Row] = [] { didSet { reload() } }
    public var selectedValue: String?
    public var statusText: String? { didSet { status.text = statusText ?? ""; status.isHidden = statusText == nil; resizePopup() } }
    /// "Start from remote": nil hides the row.
    public var startFromOrigin: Bool? { didSet { originRow.isHidden = startFromOrigin == nil; originSwitch.isOn = startFromOrigin ?? false; resizePopup() } }
    public var width: CGFloat = 320
    public var hasNextPage = false

    public var onQuery: (@MainActor (String) -> Void)?
    public var onPick: (@MainActor (String) -> Void)?
    public var onStartFromOrigin: (@MainActor (Bool) -> Void)?
    public var onLoadMore: (@MainActor () -> Void)?

    public let search = InputView(placeholder: "Search refs...", size: .sm)
    private let searchIcon = IconView(name: .search, size: 16)
    private let underline = CALayer()
    private let list = DSView()
    private let emptyLabel = LabelView("No refs found.", font: DSFont.ui(14))
    private var rowViews: [BranchPickerRowView] = []
    private var scrollOffset: CGFloat = 0
    private let originRow = DSView()
    private let originRule = CALayer()
    private let originIcon = IconView(name: .refreshCw, size: 12)
    private let originLabel = LabelView("Start from remote", font: DSFont.ui(12, weight: .medium))
    let originSwitch = SwitchView()
    private let status = LabelView("", font: DSFont.ui(12, weight: .medium))
    private(set) var highlighted: Int? { didSet { if highlighted != oldValue { rowViews.forEach { $0.restyle() }; scrollToHighlight() } } }
    private var query = ""

    /// Opens the picker as a popup next to `trigger` with the search field focused.
    @discardableResult
    public func present(from trigger: NSView, placement: PopupPlacement) -> OpenPopup? {
        guard let host = trigger.popupHost else { return nil }
        let popup = host.open(PickerPopupView(self), trigger: trigger, placement: placement, swallowsOutsideClick: true)
        trigger.window?.makeFirstResponder(search)
        return popup
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        underline.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        originRule.actions = underline.actions
        layer?.addSublayer(underline)
        list.clipsToBounds = true
        addSubview(list)
        search.unstyled = true
        search.paddingOverride = (20, 0)
        search.setAccessibilityLabel("Search refs")
        search.onChange = { [weak self] text in self?.setQuery(text) }
        search.onStateChange = { [weak self] _ in self?.needsDisplay = true }
        addSubview(search)
        addSubview(searchIcon)
        emptyLabel.lineHeight = 20
        emptyLabel.alignment = .center
        list.addSubview(emptyLabel)
        originRow.layer?.addSublayer(originRule)
        originLabel.lineHeight = 16
        originSwitch.size = .sm
        originSwitch.setAccessibilityLabel("Start worktree from remote")
        originSwitch.onChange = { [weak self] on in self?.onStartFromOrigin?(on) }
        for v in [originIcon, originLabel, originSwitch] as [NSView] { originRow.addSubview(v) }
        TooltipController.attach(to: originRow, text: "Uses the latest commit of the base branch’s tracked remote branch, even if its name differs. Otherwise uses the same-named branch on origin. Uses your local branch if that remote branch is missing.")
        originRow.isHidden = true
        addSubview(originRow)
        status.lineHeight = 16
        status.isHidden = true
        addSubview(status)
        reload()
    }

    private func setQuery(_ text: String) {
        query = text
        scrollOffset = 0
        onQuery?(text)
    }

    private func reload() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rows.indices.map { i in
            let v = BranchPickerRowView(row: rows[i], selected: rows[i].value == selectedValue)
            v.isHighlighted = { [weak self] in self?.highlighted == i }
            v.onHover = { [weak self] in self?.highlighted = i }
            v.action = { [weak self] in self?.choose(i) }
            list.addSubview(v)
            return v
        }
        emptyLabel.isHidden = !rows.isEmpty
        // `autoHighlight`: the first match while filtering.
        highlighted = query.trimmingCharacters(in: .whitespaces).isEmpty || rows.isEmpty ? nil : rows.firstIndex { !$0.disabled }
        needsLayout = true
        resizePopup()
    }

    private func choose(_ i: Int) {
        guard rows.indices.contains(i), !rows[i].disabled else { return }
        onPick?(rows[i].value)
    }

    // MARK: Size and layout

    private var listHeight: CGFloat {
        rows.isEmpty ? 36 : min(Self.maxListHeight, contentListHeight)
    }
    private var contentListHeight: CGFloat { Self.listTop + CGFloat(rows.count) * Self.rowHeight + Self.listBottom }
    private var originHeight: CGFloat { originRow.isHidden ? 0 : 35 }
    private var statusHeight: CGFloat { status.isHidden ? 0 : 32 }

    public var naturalSize: CGSize {
        CGSize(width: width - 2, height: Self.searchHeight + listHeight + originHeight + statusHeight)
    }

    private func resizePopup() {
        guard let popupView = superview?.superview as? PickerPopupView, let host = popupView.superview?.superview as? PopupHost,
              let popup = host.popups.first(where: { $0.content === popupView }) else { return }
        host.reposition(popup)
    }

    public override func layout() {
        super.layout()
        let contentW = bounds.width - 24
        search.frame = NSRect(x: 12, y: 9, width: contentW, height: 26)
        searchIcon.frame = NSRect(x: 12, y: 15, width: 16, height: 16)
        underline.frame = CGRect(x: 12, y: 41, width: contentW, height: 1)
        let listH = max(0, bounds.height - Self.searchHeight - originHeight - statusHeight)
        list.frame = NSRect(x: 0, y: Self.searchHeight, width: bounds.width, height: listH)
        scrollOffset = min(scrollOffset, maxScroll)
        var y = Self.listTop - scrollOffset
        for row in rowViews {
            row.frame = NSRect(x: Self.rowLeft, y: y, width: list.bounds.width - Self.rowLeft - Self.rowRight, height: Self.rowHeight)
            y += Self.rowHeight
        }
        emptyLabel.frame = NSRect(x: 8, y: 8, width: list.bounds.width - 16, height: 20)
        var bottom = list.frame.maxY
        if !originRow.isHidden {
            originRow.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: 35)
            originRule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
            originIcon.frame = NSRect(x: 12, y: 12, width: 12, height: 12)
            originLabel.frame = NSRect(x: 30, y: 10, width: ceil(originLabel.textWidth), height: 16)
            let s = originSwitch.intrinsicContentSize
            originSwitch.frame = NSRect(x: bounds.width - 12 - s.width, y: 1 + (34 - s.height) / 2, width: s.width, height: s.height)
            bottom += 35
        }
        status.frame = NSRect(x: 12, y: bottom + 8, width: bounds.width - 24, height: 16)
    }

    private var maxScroll: CGFloat { max(0, contentListHeight - list.bounds.height) }

    private func scrollToHighlight() {
        guard let i = highlighted, list.bounds.height > 0, i < rowViews.count else { return }
        let top = Self.listTop + CGFloat(i) * Self.rowHeight, bottom = top + Self.rowHeight
        if top - Self.listTop < scrollOffset { scrollOffset = top - Self.listTop }
        else if bottom + Self.listBottom > scrollOffset + list.bounds.height { scrollOffset = bottom + Self.listBottom - list.bounds.height }
        needsLayout = true
        maybeLoadMore()
    }

    public override func scrollWheel(with event: NSEvent) {
        scrollOffset = min(max(0, scrollOffset - event.scrollingDeltaY), maxScroll)
        needsLayout = true
        maybeLoadMore()
    }

    /// `shouldLoadNextBranchPageAfterScroll`: within a few rows of the end.
    private func maybeLoadMore() {
        if hasNextPage, maxScroll - scrollOffset < Self.rowHeight * 4 { onLoadMore?() }
    }

    public override func updateLayer() {
        underline.backgroundColor = (search.state.focused ? Themed.color(\.ring) : Themed.color(\.border, 0.7)).cgColor(in: self)
        originRule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        searchIcon.strokeColor = Themed.color(\.contrastMutedForeground, 0.55)
        emptyLabel.color = Themed.color(\.contrastMutedForeground)
        originIcon.strokeColor = Themed.color(\.contrastMutedForeground)
        originLabel.color = Themed.color(\.contrastMutedForeground)
        status.color = Themed.color(\.contrastMutedForeground)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        rowViews.forEach { $0.restyle() }
    }

    // MARK: Keyboard (base-ui Combobox: arrows wrap, Enter picks the highlighted row)

    public func handleKey(_ key: PopupKey) -> Bool {
        switch key {
        case .down, .up:
            let enabled = rows.indices.filter { !rows[$0].disabled }
            guard !enabled.isEmpty else { return true }
            if let h = highlighted, let pos = enabled.firstIndex(of: h) {
                highlighted = enabled[(pos + (key == .down ? 1 : -1) + enabled.count) % enabled.count]
            } else {
                highlighted = key == .down ? enabled.first : enabled.last
            }
            return true
        case .enter:
            if let h = highlighted { choose(h) }
            return true
        default:
            return false
        }
    }
}

/// `BranchPickerRefItem` and the synthetic rows: `ComboboxItem hideIndicator`, 28pt, `px-2 rounded-sm text-sm`,
/// the name middle-truncated, the badge in `text-3xs text-muted-foreground/45`.
final class BranchPickerRowView: ControlView {
    let row: BranchPickerView.Row
    let selected: Bool
    private let fill = CALayer()
    private let title = MiddleTruncateView("", font: DSFont.ui(14))
    private let plain = LabelView()
    private let badge = LabelView()
    var isHighlighted: () -> Bool = { false }
    var onHover: (@MainActor () -> Void)?

    init(row: BranchPickerView.Row, selected: Bool) {
        self.row = row
        self.selected = selected
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = 6
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        title.value = row.middleTruncates ? row.title : ""
        title.showsTitle = false
        title.isHidden = !row.middleTruncates
        plain.text = row.middleTruncates ? "" : row.title
        plain.font = DSFont.ui(14)
        plain.lineHeight = 20
        plain.isHidden = row.middleTruncates
        badge.text = row.badge ?? ""
        badge.font = DSFont.ui(10)
        badge.lineHeight = 14
        badge.isHidden = row.badge == nil
        addSubview(title)
        addSubview(plain)
        addSubview(badge)
        isEnabled = !row.disabled
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(row.title)
        restyle()
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if state.hovered && !old.hovered { onHover?() }
        restyle()
    }

    func restyle() {
        needsDisplay = true
        applyColors()
    }

    override func updateLayer() { applyColors() }

    private func applyColors() {
        let lit = isHighlighted()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = lit ? Themed.color(\.accent).cgColor(in: self)
            : selected ? Themed.color(\.contrastForeground, 0.08).cgColor(in: self) : nil
        CATransaction.commit()
        let text = lit ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
        title.color = text
        plain.color = text
        badge.color = Themed.color(\.contrastMutedForeground, 0.45)
        setAccessibilitySelected(selected)
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        var right = bounds.width - 8
        if !badge.isHidden {
            let w = ceil(badge.textWidth)
            badge.frame = NSRect(x: right - w, y: (bounds.height - 14) / 2, width: w, height: 14)
            right -= w + 8
        }
        let frame = NSRect(x: 8, y: (bounds.height - 20) / 2, width: max(0, right - 8), height: 20)
        title.frame = frame
        plain.frame = frame
    }
}
