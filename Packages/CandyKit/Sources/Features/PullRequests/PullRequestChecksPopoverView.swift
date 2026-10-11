import AppKit
import DesignSystem
import T3Protocol

/// `PullRequestChecksPopover` (PullRequestChecksPopover.tsx:132-219): the rollup's headline, the
/// summary when the checks are in hand, then the checks needing attention and the running ones,
/// with the completed ones behind "Show all". A listing row knows only the rollup, so its popover
/// starts in `.loading` and the caller reads the detail (`LazyChecksBody`, lines 34-57).
public final class PullRequestChecksPopoverView: DSView {
    public enum Body: Equatable, Sendable {
        case checks([PullRequestCheck])
        case loading
        case message(String)
        /// "Check details are out of date. Refresh the pull request to update them."
        case stale
    }

    static let width: CGFloat = 320 - 2 - 32
    static let maxListHeight: CGFloat = 256

    private let headline = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let summary = LabelView("", font: DSFont.ui(12))
    private let note = TextBlockView()
    private let list = PullRequestChecksListView()
    private let scroll: ScrollAreaView
    private let toggle = ButtonView("Show all", variant: .ghost, size: .xs)
    private var showAll = false
    public var body: Body = .loading { didSet { rebuild() } }
    public var onOpenURL: ((String) -> Void)?

    /// `checksState` names the headline; `summary` is nil for a listing row or stale checks.
    public init(checksState: String, summary summaryText: String?, body: Body) {
        scroll = ScrollAreaView(documentView: list)
        self.body = body
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 40))
        headline.text = PullRequestDetailLogic.checksStateLabel(checksState)
        headline.lineHeight = 20
        summary.text = summaryText ?? ""
        summary.isHidden = summaryText == nil
        summary.lineHeight = 16
        note.font = DSFont.ui(12)
        note.lineHeight = 16
        [headline, self.summary, note, scroll, toggle].forEach(addSubview)
        toggle.action = { [weak self] in
            guard let self else { return }
            self.showAll.toggle()
            self.rebuild()
            self.resizePopup()
        }
        list.onOpenURL = { [weak self] url in self?.onOpenURL?(url) }
        setAccessibilityLabel("Checks")
        rebuild()
    }

    private var visibleChecks: [PullRequestCheck] {
        guard case .checks(let checks) = body else { return [] }
        let g = PullRequestDetailLogic.groupChecks(checks)
        let canCollapse = g.attention.count + g.running.count > 0 && !g.completed.isEmpty
        return g.attention + g.running + (showAll || !canCollapse ? g.completed : [])
    }

    private var canCollapse: Bool {
        guard case .checks(let checks) = body else { return false }
        let g = PullRequestDetailLogic.groupChecks(checks)
        return g.attention.count + g.running.count > 0 && !g.completed.isEmpty
    }

    private func rebuild() {
        switch body {
        case .checks(let checks) where !checks.isEmpty:
            note.isHidden = true
            list.checks = visibleChecks
        case .checks:
            note.text = "No checks reported"
            note.isHidden = false
            list.checks = []
        case .loading:
            note.text = "Loading checks…"
            note.isHidden = false
            list.checks = []
        case .message(let text):
            note.text = text
            note.isHidden = false
            list.checks = []
        case .stale:
            note.text = "Check details are out of date. Refresh the pull request to update them."
            note.isHidden = false
            list.checks = []
        }
        scroll.isHidden = list.checks.isEmpty
        toggle.isHidden = !canCollapse
        toggle.title = showAll ? "Show less" : "Show all"
        toggle.setAccessibilityLabel(toggle.title)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func resizePopup() {
        guard let popover = superview as? PopoverView, let host = popover.superview?.superview as? PopupHost,
              let popup = host.popups.first(where: { $0.content === popover }) else { return }
        popover.invalidateIntrinsicContentSize()
        host.reposition(popup)
    }

    private var listHeight: CGFloat { min(Self.maxListHeight, list.height) }

    public override var intrinsicContentSize: NSSize {
        var h: CGFloat = 20 + 8
        if !summary.isHidden { h += 16 + 8 }
        if !note.isHidden { h += note.height(forWidth: Self.width) }
        if !scroll.isHidden { h += listHeight }
        if !toggle.isHidden { h += 24 }
        return NSSize(width: Self.width, height: h)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        headline.frame = NSRect(x: 0, y: 0, width: w, height: 20)
        var y: CGFloat = 28
        if !summary.isHidden { summary.frame = NSRect(x: 0, y: y, width: w, height: 16); y += 24 }
        if !note.isHidden {
            let h = note.height(forWidth: w)
            note.frame = NSRect(x: 0, y: y, width: w, height: h); y += h
        }
        if !scroll.isHidden {
            scroll.frame = NSRect(x: 0, y: y, width: w, height: listHeight)
            list.frame = NSRect(x: 0, y: 0, width: w, height: list.height)
            y += listHeight
        }
        if !toggle.isHidden {
            let tw = ceil(toggle.intrinsicContentSize.width)
            toggle.frame = NSRect(x: 0, y: y, width: tw, height: 24)
        }
    }

    public override func updateLayer() {
        headline.color = Themed.color(\.popoverForeground)
        summary.color = Themed.color(\.mutedForeground)
        note.color = Themed.color(\.mutedForeground)
    }
}

/// The `ul.flex-col.gap-1` of checks: glyph, name (tooltip: description), status word, "Details".
final class PullRequestChecksListView: DSView {
    var checks: [PullRequestCheck] = [] { didSet { rebuild() } }
    var onOpenURL: ((String) -> Void)?
    private var rows: [(glyph: CheckStatusGlyph, name: LabelView, status: LabelView, details: LinkLabel?)] = []

    var height: CGFloat { checks.isEmpty ? 0 : CGFloat(checks.count) * 16 + CGFloat(checks.count - 1) * 4 }

    private func rebuild() {
        for r in rows { r.glyph.removeFromSuperview(); r.name.removeFromSuperview(); r.status.removeFromSuperview(); r.details?.removeFromSuperview() }
        rows = checks.map { c in
            let p = PullRequestStyle.checkStatus(c.status)
            let glyph = CheckStatusGlyph()
            glyph.set(icon: p.icon, color: p.color, spinning: c.status == "pending")
            let name = LabelView(c.name, font: DSFont.ui(12))
            name.lineHeight = 16
            name.toolTip = c.description ?? c.name
            let status = LabelView(PullRequestDetailLogic.checkStatusLabel(c), font: DSFont.ui(12))
            status.lineHeight = 16
            var details: LinkLabel?
            if let url = c.url {
                let l = LinkLabel()
                l.text = "Details"
                l.font = DSFont.ui(12)
                l.onClick = { [weak self] in self?.onOpenURL?(url) }
                details = l
            }
            [glyph, name, status].forEach(addSubview)
            details.map(addSubview)
            return (glyph, name, status, details)
        }
        restyle()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        for (i, r) in rows.enumerated() {
            let y = CGFloat(i) * 20
            r.glyph.frame = NSRect(x: 0, y: y + 1, width: 14, height: 14)
            var right = w
            if let d = r.details {
                let dw = ceil(d.textWidth) + 1
                d.frame = NSRect(x: right - dw, y: y, width: dw, height: 16)
                right -= dw + 8
            }
            let sw = ceil(r.status.textWidth) + 1
            r.status.frame = NSRect(x: right - sw, y: y, width: sw, height: 16)
            right -= sw + 8
            r.name.frame = NSRect(x: 22, y: y, width: max(0, right - 22), height: 16)
        }
    }

    private func restyle() {
        for r in rows {
            r.name.color = Themed.color(\.popoverForeground)
            r.status.color = Themed.color(\.mutedForeground)
            r.details?.color = Themed.color(\.primary)
        }
    }

    override func updateLayer() { restyle() }
}

extension PullRequestChecksPopoverView {
    /// Opens the popover under `trigger` (`align="start" side="bottom" width="md"`).
    @discardableResult
    public func present(from trigger: NSView) -> OpenPopup? {
        PopoverView(content: self, width: .md).show(from: trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .end))
    }
}
