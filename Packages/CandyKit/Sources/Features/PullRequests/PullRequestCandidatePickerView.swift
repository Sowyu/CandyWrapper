import AppKit
import DesignSystem
import T3Protocol

/// `PullRequestCandidatePicker` (PullRequestCandidatePicker.tsx:23-164), the shell the label and
/// reviewer pickers share: a `w-72` combobox popup with a search box, then the loading ghost, the
/// error, the empty or no-match line, or the rows, and the truncation note. It stays open on a pick:
/// a change shows as the row's check turning over. The caller reads the candidates once it opens
/// and narrows them with `PullRequestWriteLogic.filterLabels` or `filterReviewers`.
public final class PullRequestCandidatePickerView: DSView, PickerPopupBody {
    public enum Kind: Sendable { case labels, reviewers }
    public enum State: Equatable, Sendable { case loading, failed(String), loaded }

    /// One row: a label or a person.
    public struct Row: Equatable {
        public var key: String
        public var title: String
        public var detail: String?
        public var dot: NSColor?
        public var actor: PullRequestActor?
        public var trailing: String?
        public var checked: Bool
        public init(key: String, title: String, detail: String? = nil, dot: NSColor? = nil, actor: PullRequestActor? = nil,
                    trailing: String? = nil, checked: Bool) {
            self.key = key; self.title = title; self.detail = detail; self.dot = dot; self.actor = actor; self.trailing = trailing; self.checked = checked
        }
    }

    static let searchHeight: CGFloat = 43, rowHeight: CGFloat = 32, maxListHeight: CGFloat = 288

    public let kind: Kind
    public var state: State = .loading { didSet { reload() } }
    public var rows: [Row] = [] { didSet { reload() } }
    public var truncated = false { didSet { reload() } }
    /// Every row locks while one change is in flight.
    public var disabled = false { didSet { rowViews.forEach { $0.isEnabled = !disabled } } }
    public var onQuery: ((String) -> Void)?
    public var onPick: ((String) -> Void)?

    public let search: InputView
    private let searchIcon = IconView(name: .search, size: 16)
    private let underline = CALayer()
    private let list = DSView()
    private let note = TextBlockView()
    private let truncatedNote = TextBlockView()
    private var ghosts: [SkeletonView] = []
    private var rowViews: [PullRequestCandidateRowView] = []
    private var scrollOffset: CGFloat = 0
    private var query = ""
    private(set) var highlighted: Int? { didSet { if highlighted != oldValue { rowViews.forEach { $0.restyle() } } } }

    /// The words that change between the two pickers (LabelPicker.tsx:83-104, ReviewerPicker.tsx:98-120).
    var words: (search: String, empty: String, noMatch: String, error: String, truncated: String) {
        switch kind {
        case .labels: ("Search labels", "This repository has no labels.", "No label matches that.", "The labels could not be read.",
                       "This repository has more labels than are listed here. Apply the rest on the host.")
        case .reviewers: ("Search people with access", "Nobody else has access to this repository.", "Nobody with access matches that.",
                          "The people with access could not be read.",
                          "This repository has more people with access than are listed here. Ask for the rest on the host.")
        }
    }

    public init(kind: Kind) {
        self.kind = kind
        search = InputView(placeholder: "", size: .sm)
        super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 120))
        clipsToBounds = true
        underline.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(underline)
        list.clipsToBounds = true
        addSubview(list)
        search.unstyled = true
        search.paddingOverride = (20, 0)
        search.placeholder = words.search
        search.setAccessibilityLabel(words.search)
        search.onChange = { [weak self] text in self?.query = text; self?.scrollOffset = 0; self?.onQuery?(text) }
        search.onStateChange = { [weak self] _ in self?.needsDisplay = true }
        addSubview(search)
        addSubview(searchIcon)
        for n in [note, truncatedNote] { n.font = DSFont.ui(12); n.lineHeight = 16; list.addSubview(n) }
        ghosts = (0..<4).map { _ in SkeletonView(shape: .pill) }
        ghosts.forEach(list.addSubview)
        reload()
    }

    @discardableResult
    public func present(from trigger: NSView) -> OpenPopup? {
        guard let host = trigger.popupHost else { return nil }
        let popup = host.open(PickerPopupView(self), trigger: trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                              swallowsOutsideClick: true)
        trigger.window?.makeFirstResponder(search)
        return popup
    }

    private func reload() {
        rowViews.forEach { $0.removeFromSuperview() }
        let showRows = state == .loaded && !rows.isEmpty
        rowViews = showRows ? rows.indices.map { i in
            let v = PullRequestCandidateRowView(row: rows[i])
            v.isHighlighted = { [weak self] in self?.highlighted == i }
            v.onHover = { [weak self] in self?.highlighted = i }
            v.action = { [weak self] in self?.choose(i) }
            v.isEnabled = !disabled
            list.addSubview(v)
            return v
        } : []
        ghosts.forEach { $0.isHidden = state != .loading }
        switch state {
        case .loading: note.text = ""
        case .failed(let message): note.text = "\(words.error) \(message)"
        case .loaded: note.text = rows.isEmpty ? (query.isEmpty ? words.empty : words.noMatch) : ""
        }
        note.isHidden = note.text.isEmpty
        truncatedNote.text = words.truncated
        truncatedNote.isHidden = !truncated
        // `autoHighlight`.
        highlighted = rowViews.isEmpty ? nil : 0
        needsLayout = true
        resizePopup()
    }

    private func choose(_ i: Int) {
        guard rows.indices.contains(i), !disabled else { return }
        onPick?(rows[i].key)
    }

    private var contentHeight: CGFloat {
        var h: CGFloat = 4
        switch state {
        case .loading: h += 4 * 28
        case .failed, .loaded: h += rowViews.isEmpty ? 8 + note.height(forWidth: 286 - 16) + 8 : CGFloat(rowViews.count) * Self.rowHeight
        }
        if truncated { h += 6 + truncatedNote.height(forWidth: 286 - 16) + 6 }
        return h + 4
    }

    public var naturalSize: CGSize { CGSize(width: 288 - 2, height: Self.searchHeight + min(Self.maxListHeight, contentHeight)) }

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
        list.frame = NSRect(x: 0, y: Self.searchHeight, width: bounds.width, height: max(0, bounds.height - Self.searchHeight))
        scrollOffset = min(scrollOffset, max(0, contentHeight - list.bounds.height))
        var y = 4 - scrollOffset
        for (i, g) in ghosts.enumerated() { g.frame = NSRect(x: 8, y: y + CGFloat(i) * 28 + 8, width: [160, 120, 140, 100][i], height: 12) }
        if !note.isHidden {
            let h = note.height(forWidth: list.bounds.width - 16)
            note.frame = NSRect(x: 8, y: y + 8, width: list.bounds.width - 16, height: h)
            y += 8 + h + 8
        }
        for row in rowViews {
            row.frame = NSRect(x: 4, y: y, width: list.bounds.width - 8, height: Self.rowHeight)
            y += Self.rowHeight
        }
        if state == .loading { y += 4 * 28 }
        if truncated {
            let h = truncatedNote.height(forWidth: list.bounds.width - 16)
            truncatedNote.frame = NSRect(x: 8, y: y + 6, width: list.bounds.width - 16, height: h)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        scrollOffset = min(max(0, scrollOffset - event.scrollingDeltaY), max(0, contentHeight - list.bounds.height))
        needsLayout = true
    }

    public override func updateLayer() {
        underline.backgroundColor = (search.state.focused ? Themed.color(\.ring) : Themed.color(\.border, 0.7)).cgColor(in: self)
        searchIcon.strokeColor = Themed.color(\.contrastMutedForeground, 0.55)
        note.color = Themed.color(\.contrastMutedForeground)
        truncatedNote.color = Themed.color(\.contrastMutedForeground)
    }

    public func handleKey(_ key: PopupKey) -> Bool {
        switch key {
        case .down, .up:
            guard !rowViews.isEmpty else { return true }
            let n = rowViews.count
            highlighted = highlighted.map { ($0 + (key == .down ? 1 : -1) + n) % n } ?? (key == .down ? 0 : n - 1)
            return true
        case .enter:
            if let h = highlighted { choose(h) }
            return true
        default:
            return false
        }
    }
}

/// A candidate row (`ComboboxItem hideIndicator`): the label's dot or the person's avatar, the name
/// (and ` · description` muted), "team", and the check when it applies.
final class PullRequestCandidateRowView: ControlView {
    let row: PullRequestCandidatePickerView.Row
    private let fill = CALayer()
    private let dot = CALayer()
    private let avatar: PullRequestAvatarView?
    private let title = LabelView("", font: DSFont.ui(14))
    private let trailing = LabelView("", font: DSFont.ui(14))
    private let detail = LabelView("", font: DSFont.ui(14))
    private let check = IconView(name: .check, size: 14)
    var isHighlighted: () -> Bool = { false }
    var onHover: (@MainActor () -> Void)?

    init(row: PullRequestCandidatePickerView.Row) {
        self.row = row
        avatar = row.actor == nil ? nil : PullRequestAvatarView()
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = 6
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        if row.actor == nil {
            dot.cornerRadius = 4
            layer?.addSublayer(dot)
        }
        avatar?.actor = row.actor
        avatar.map(addSubview)
        title.text = row.title
        title.lineHeight = 20
        detail.text = row.detail.map { " · \($0)" } ?? ""
        detail.lineHeight = 20
        detail.isHidden = row.detail == nil
        addSubview(detail)
        trailing.text = row.trailing ?? ""
        trailing.lineHeight = 20
        trailing.isHidden = row.trailing == nil
        check.isHidden = !row.checked
        check.setAccessibilityLabel(row.actor == nil ? "Applied" : "Already asked")
        [title, trailing, check].forEach(addSubview)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(row.title)
        restyle()
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if state.hovered && !old.hovered { onHover?() }
        restyle()
    }

    func restyle() { needsDisplay = true; applyColors() }
    override func updateLayer() { applyColors() }

    private func applyColors() {
        let lit = isHighlighted()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = lit ? Themed.color(\.accent).cgColor(in: self) : nil
        dot.backgroundColor = (row.dot ?? Themed.color(\.mutedForeground)).cgColor(in: self)
        CATransaction.commit()
        let text = lit ? Themed.color(\.contrastAccentForeground) : Themed.color(\.contrastForeground)
        title.color = text
        detail.color = Themed.color(\.contrastMutedForeground)
        trailing.color = Themed.color(\.contrastMutedForeground)
        check.strokeColor = text
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        var x: CGFloat = 8
        if let avatar {
            avatar.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16); x += 16 + 8
        } else {
            dot.frame = CGRect(x: x, y: (bounds.height - 8) / 2, width: 8, height: 8); x += 8 + 8
        }
        var right = bounds.width - 8
        if !check.isHidden { check.frame = NSRect(x: right - 14, y: (bounds.height - 14) / 2, width: 14, height: 14); right -= 14 + 8 }
        if !trailing.isHidden {
            let w = ceil(trailing.textWidth) + 1
            trailing.frame = NSRect(x: right - w, y: (bounds.height - 20) / 2, width: w, height: 20); right -= w + 8
        }
        let tw = min(ceil(title.textWidth) + 1, max(0, right - x))
        title.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: tw, height: 20)
        detail.frame = NSRect(x: x + tw, y: (bounds.height - 20) / 2, width: max(0, right - x - tw), height: 20)
    }
}
