import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// One subagent's pending approval shown in its parent (`ChildThreadApproval`, client-runtime threadRequests.ts:373-416
/// at 4928, #28516).
public struct ChildApproval: Hashable, Sendable {
    public var threadId: ThreadId
    public var title: String
    public var approval: PendingApproval
    public init(threadId: ThreadId, title: String, approval: PendingApproval) {
        self.threadId = threadId
        self.title = title
        self.approval = approval
    }
    var key: String { "\(threadId.rawValue)\n\(approval.requestId)" }
}

/// `ChildThreadApprovals` (apps/web/src/components/chat/ChildThreadApprovals.tsx:84-95 at 4928): the cards of the subagents
/// waiting on an approval, above the composer and outside its banner stack. `mb-2 flex max-h-80 flex-col gap-2
/// overflow-auto`. The view holds nothing while no child asks.
public final class ChildApprovalsView: NSView {
    /// Answers a child's request; returns an error message, or nil once the server took it.
    public var onRespond: (@MainActor (ThreadId, String, ApprovalDecision) async -> String?)?
    public private(set) var entries: [ChildApproval] = []
    public var canRespond = true { didSet { if canRespond != oldValue { cards.forEach { $0.refresh() } } } }

    private var scroll: NSScrollView?
    private let document = FlippedView()
    private var cards: [ChildApprovalCardView] = []
    static let maxHeight: CGFloat = 320
    static let gap: CGFloat = 8

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public var isEmpty: Bool { entries.isEmpty }

    /// Shows these approvals, keeping the card (and its in-flight state) of one already shown.
    public func set(_ next: [ChildApproval]) {
        guard next != entries else { return }
        entries = next
        guard !next.isEmpty else {
            cards.forEach { $0.removeFromSuperview() }
            cards = []
            scroll?.removeFromSuperview()
            scroll = nil
            superview?.needsLayout = true
            return
        }
        if scroll == nil {
            let made = NSScrollView()
            made.drawsBackground = false
            made.hasVerticalScroller = true
            made.autohidesScrollers = true
            made.scrollerStyle = .overlay
            made.documentView = document
            addSubview(made)
            scroll = made
        }
        var byKey = Dictionary(cards.map { ($0.entry.key, $0) }, uniquingKeysWith: { a, _ in a })
        cards = next.map { entry in
            let card = byKey.removeValue(forKey: entry.key) ?? ChildApprovalCardView(owner: self)
            card.entry = entry
            if card.superview !== document { document.addSubview(card) }
            return card
        }
        byKey.values.forEach { $0.removeFromSuperview() }
        needsLayout = true
        superview?.needsLayout = true
    }

    func respond(_ entry: ChildApproval, _ decision: ApprovalDecision) async -> String? {
        await onRespond?(entry.threadId, entry.approval.requestId, decision) ?? nil
    }

    private func contentHeight(_ width: CGFloat) -> CGFloat {
        cards.reduce(0) { $0 + $1.height(forWidth: width) } + Self.gap * CGFloat(max(0, cards.count - 1))
    }

    /// The list's height without its `mb-2`.
    public func height(forWidth width: CGFloat) -> CGFloat { min(Self.maxHeight, contentHeight(width)) }

    public override func layout() {
        super.layout()
        guard let scroll else { return }
        scroll.frame = bounds
        let width = bounds.width
        var y: CGFloat = 0
        for card in cards {
            let h = card.height(forWidth: width)
            card.frame = NSRect(x: 0, y: y, width: width, height: h)
            y += h + Self.gap
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(0, y - Self.gap))
    }
}

/// `ChildApproval` (ChildThreadApprovals.tsx:16-82): `rounded-lg border border-border bg-background p-3 text-xs`, the
/// title, the request in mono capped at `max-h-40`, the app, the gone-provider warning, the reason, the full-access
/// explanation, then T3's inline approval buttons (`ComposerPendingApprovalActions presentation="inline"`).
final class ChildApprovalCardView: DSView {
    weak var owner: ChildApprovalsView?
    var entry = ChildApproval(threadId: "", title: "", approval: PendingApproval(requestId: "", requestKind: .command)) {
        didSet { if entry != oldValue { refresh() } }
    }
    /// `rounded-lg border border-border bg-background`.
    private let box = FillView()
    private let title = TextBlockView()
    private let detailScroll = NSScrollView()
    private let detail = TextBlockView()
    private var notes: [TextBlockView] = []
    private var actions: [ThreadStatusLineAction] = []
    private let more = ThreadStatusLineAction()
    private let errorText = TextBlockView()
    private var responding = false
    private var error: String?

    init(owner: ChildApprovalsView) {
        self.owner = owner
        super.init(frame: .zero)
        box.radius = 8
        box.border = Themed.color(\.border)
        box.fill = Themed.color(\.background)
        addSubview(box)
        title.font = DSFont.ui(12, weight: .medium)
        title.lineHeight = 16
        detail.font = DSFont.mono(12)
        detail.lineHeight = 16
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.scrollerStyle = .overlay
        detailScroll.documentView = detail
        errorText.font = DSFont.ui(12)
        errorText.lineHeight = 16
        errorText.color = Themed.color(\.destructive)
        errorText.setAccessibilityRole(.staticText)
        more.label.text = "More"
        more.tone = .muted
        more.setAccessibilityLabel("More approval options")
        more.action = { [weak self] in self?.openMenu() }
        [title, detailScroll, more, errorText].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    private var enabled: Bool { (owner?.canRespond ?? false) && entry.approval.canRespond && !responding }

    func refresh() {
        let approval = entry.approval
        setAccessibilityLabel("Approval from \(entry.title)")
        title.text = "Approval needed from \(entry.title)"
        title.color = Themed.color(\.foreground)
        detail.text = approval.detail.flatMap { $0.isEmpty ? nil : $0 } ?? approval.requestKind.rawValue
        detail.color = Themed.color(\.foreground)
        notes.forEach { $0.removeFromSuperview() }
        var lines: [(String, KeyPath<Palette, TokenColor>)] = []
        if let app = approval.appName { lines.append((app, \.mutedForeground)) }
        if !approval.canRespond { lines.append(("Provider process is gone. Interrupt or restart the child thread to respond.", \.warning)) }
        if let reason = approval.reason { lines.append((reason, \.mutedForeground)) }
        if let why = approval.fullAccessOverrideExplanation { lines.append((why, \.mutedForeground)) }
        notes = lines.map { text, color in
            let note = TextBlockView()
            note.font = DSFont.ui(12)
            note.lineHeight = 16
            note.text = text
            note.color = Themed.color(color)
            addSubview(note)
            return note
        }
        actions.forEach { $0.removeFromSuperview() }
        actions = approval.buttonOptions.map { option in
            let action = ThreadStatusLineAction()
            action.label.text = option.label
            action.tone = option.decision == .accept ? .foreground : .muted
            action.action = { [weak self] in self?.respond(option.decision) }
            if let warning = option.warning { TooltipController.attach(to: action, text: warning) }
            addSubview(action)
            return action
        }
        more.isHidden = approval.menuOptions.isEmpty
        for action in actions + [more] { action.isEnabled = enabled }
        errorText.text = error ?? ""
        errorText.isHidden = error == nil
        needsDisplay = true
        needsLayout = true
        superview?.superview?.superview?.needsLayout = true
    }

    private func respond(_ decision: ApprovalDecision) {
        guard enabled, let owner else { return }
        responding = true
        error = nil
        refresh()
        let entry = self.entry
        Task { @MainActor [weak self] in
            let message = await owner.respond(entry, decision)
            guard let self else { return }
            self.responding = false
            self.error = message
            self.refresh()
        }
    }

    private func openMenu() {
        let items = entry.approval.menuOptions.map { option in
            MenuItem(option.label, icon: option.warning == nil ? nil : .triangleAlert, disabled: !enabled) { [weak self] in self?.respond(option.decision) }
        }
        MenuPopupView.show(items, from: more, placement: PopupPlacement(side: .top, align: .end), fitsContent: true)
    }

    private static let pad: CGFloat = 12
    private var detailMaxHeight: CGFloat { 160 }

    private func inner(_ width: CGFloat) -> CGFloat { max(1, width - 2 * Self.pad) }

    func height(forWidth width: CGFloat) -> CGFloat {
        let w = inner(width)
        var h = Self.pad + title.height(forWidth: w) + 8 + min(detailMaxHeight, detail.height(forWidth: w))
        for note in notes { h += 8 + note.height(forWidth: w) }
        h += 8 + actionRows(w).height
        if error != nil { h += 8 + errorText.height(forWidth: w) }
        return h + Self.pad + 2
    }

    /// `flex flex-wrap gap-2`: each button's frame, from the row's top.
    private func actionRows(_ width: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        let views = actions + (more.isHidden ? [] : [more])
        var x: CGFloat = 0, y: CGFloat = 0
        var frames: [NSRect] = []
        for view in views {
            let w = min(width, view.preferredWidth)
            if x > 0, x + w > width { x = 0; y += 16 + 8 }
            frames.append(NSRect(x: x, y: y, width: w, height: 16))
            // `gap-2` follows the text's own advance, not the rounded-up frame.
            x += min(width, view.label.textWidth) + 8
        }
        return (frames, views.isEmpty ? 0 : y + 16)
    }

    override func layout() {
        super.layout()
        box.frame = bounds
        let w = inner(bounds.width), x = Self.pad + 1
        var y = Self.pad + 1
        let th = title.height(forWidth: w)
        title.frame = NSRect(x: x, y: y, width: w, height: th)
        y += th + 8
        let dh = detail.height(forWidth: w)
        detailScroll.frame = NSRect(x: x, y: y, width: w, height: min(detailMaxHeight, dh))
        detail.frame = NSRect(x: 0, y: 0, width: w, height: dh)
        y += min(detailMaxHeight, dh)
        for note in notes {
            y += 8
            let h = note.height(forWidth: w)
            note.frame = NSRect(x: x, y: y, width: w, height: h)
            y += h
        }
        y += 8
        let rows = actionRows(w)
        for (view, frame) in zip(actions + (more.isHidden ? [] : [more]), rows.frames) { view.frame = frame.offsetBy(dx: x, dy: y) }
        y += rows.height
        if error != nil {
            y += 8
            errorText.frame = NSRect(x: x, y: y, width: w, height: errorText.height(forWidth: w))
        }
    }

}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
