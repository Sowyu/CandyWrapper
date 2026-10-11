import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Copies text and briefly swaps the icon to a check, like `MessageCopyButton` (1.2s).
@MainActor
func copyButton() -> ButtonView {
    let button = ButtonView(icon: .copy, variant: .ghostMuted, size: .xs)
    button.iconSize = 12
    button.setAccessibilityLabel("Copy message")
    button.toolTip = "Copy message"
    return button
}

@MainActor
func copy(_ text: String, from button: ButtonView) {
    NSPasteboard.general.clearContents()
    let copied = NSPasteboard.general.setString(text, forType: .string)
    AnchoredCopyToast.show(from: button, success: copied)
    button.icon = .check
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button] in button?.icon = .copy }
}

extension MarkdownLayout {
    /// The widest thing the layout drew, for shrink-to-fit boxes such as the user bubble.
    var contentWidth: CGFloat {
        items.reduce(0) { w, item in
            switch item {
            case .text(let box, let p): max(w, p.x + box.usedWidth)
            case .box(let r, _, _, _), .checkbox(let r, _), .icon(_, let r, _), .clip(let r): max(w, r.maxX)
            default: w
            }
        }
    }
}

/// `UserMessageIntentMarker` (MessagesTimeline.tsx:2562-2603): the line above a bubble that did
/// not start its own turn. Steers show a redo arrow and "Steer"; queued turns show "Queued".
/// `me-1 flex items-center justify-end gap-1 text-xs leading-none text-muted-foreground`, icon `size-3`.
final class UserIntentMarkerView: DSView {
    static let height: CGFloat = 12
    private let icon = IconView(name: .redo2, size: 12, strokeColor: TL.c(\.mutedForeground))
    private let label = LabelView("", font: TL.font(12), color: TL.c(\.mutedForeground))

    /// Label, icon and tooltip for an intent, or nil when the row shows no marker (`turn_start`, none).
    static func presentation(_ intent: InputIntent?) -> (label: String, icon: Bool, tooltip: String)? {
        guard let intent, intent != .turnStart else { return nil }
        if intent == .queuedTurn { return ("Queued", false, "Queued behind the active turn") }
        if intent == .promotedQueuedToSteer { return ("Steer", true, "Originally queued, then promoted to steer the active turn") }
        // T3 falls back to the steer look for any other intent.
        return ("Steer", true, "Steered the active turn")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = Self.height
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ p: (label: String, icon: Bool, tooltip: String)) {
        label.text = p.label
        icon.isHidden = !p.icon
        toolTip = p.tooltip
        needsLayout = true
    }

    var fittingWidth: CGFloat { ceil(label.textWidth) + (icon.isHidden ? 0 : 12 + 4) }

    override func layout() {
        super.layout()
        let w = ceil(label.textWidth)
        label.frame = NSRect(x: bounds.width - w, y: 0, width: w, height: Self.height)
        icon.frame = NSRect(x: label.frame.minX - 4 - 12, y: 0, width: 12, height: 12)
    }
}

/// `UserTimelineRow` (MessagesTimeline.tsx:2198-2560): a right-aligned bubble at most 80% of the
/// lane, then a hover row with the time and a copy button that always keeps its 24px. A steered or
/// queued message gets its intent marker above the bubble (`flex-col gap-1`).
final class UserMessageRowView: TimelineRowView {
    static let padding: CGFloat = 12
    static let collapsedHeight: CGFloat = 176
    static let fade: CGFloat = 28

    private let bubble = FillView()
    private let markdown = MarkdownView(frame: .zero)
    private let toggle = ButtonView("Show full message", variant: .ghostMuted, size: .xs)
    private let time = LabelView("", font: TL.tabular(12), color: TL.c(\.mutedForeground))
    private let copyButton = Features.copyButton()
    private let editButton = ButtonView(icon: .pencil, variant: .ghostMuted, size: .xs)
    private let fadeMask = CAGradientLayer()
    private let marker = UserIntentMarkerView(frame: .zero)
    private var text = ""
    private var collapsible = false
    /// The image grid and file rows above the text (MessagesTimeline.tsx:2402-2490).
    private let attachments = UserMessageAttachmentsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.fill = TL.c(\.messageSurface)
        bubble.radius = 18
        addSubview(marker)
        addSubview(bubble)
        // `text-foreground` on the bubble, where assistant markdown sits at 80%.
        markdown.bodyColor = TL.c(\.foreground)
        bubble.addSubview(markdown)
        // Over the bubble, not in it: the bubble takes no clicks (`FillView`), the images do.
        addSubview(attachments)
        bubble.addSubview(toggle)
        time.lineHeight = 16
        addSubview(time)
        addSubview(copyButton)
        addSubview(editButton)
        editButton.setAccessibilityLabel("Edit from here")
        editButton.toolTip = "Edit from here"
        editButton.action = { [weak self] in
            guard let self, let m = self.item?.row.message else { return }
            self.context.model?.onEditPrompt?(m)
        }
        fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        toggle.action = { [weak self] in
            guard let self, case .message(let m, _, _, _, _, _)? = self.item?.row.kind else { return }
            self.context.model?.toggleMessage(m.id.rawValue)
        }
        copyButton.action = { [weak self] in
            guard let self else { return }
            Features.copy(self.text, from: self.copyButton)
        }
        hoverChanged()
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .message(let m, _, _, _, _, _) = item.row.kind else { return }
        text = m.text
        editButton.isHidden = m.inputIntent != .turnStart && m.inputIntent != .queuedTurn
        markdown.cwd = context.markdownCwd
        markdown.onOpenFile = context.model?.openFile
        markdown.document = context.document(item.id, m.text, lineBreaks: true)
        attachments.configure(m, model: context.model)
        collapsible = shouldCollapseUserMessage(m.text)
        toggle.title = item.ui.messageExpanded ? "Show less" : "Show full message"
        toggle.isHidden = !collapsible
        time.text = TL.dayAwareTimestamp(m.createdAt, now: context.now())
        time.toolTip = nil
        let intent = UserIntentMarkerView.presentation(m.inputIntent)
        marker.isHidden = intent == nil
        if let intent { marker.configure(intent) }
        needsLayout = true
    }

    /// The marker line and the 4px gap under it.
    private var markerSpace: CGFloat { marker.isHidden ? 0 : UserIntentMarkerView.height + 4 }

    private func metrics(_ width: CGFloat) -> (bubble: CGFloat, body: CGFloat, full: CGFloat) {
        let maxBubble = width * 0.8
        let inner = maxBubble - Self.padding * 2
        // `fit-content`: the max-content width (unwrapped) if it fits, else the full 80%.
        let natural = max(markdown.layout(forWidth: 100_000).contentWidth, attachments.naturalWidth)
        var bubbleWidth = natural > inner ? maxBubble : min(maxBubble, ceil(natural * 64) / 64 + Self.padding * 2)
        if collapsible { bubbleWidth = max(bubbleWidth, min(maxBubble, toggle.intrinsicContentSize.width - 4 + Self.padding * 2)) }
        let full = markdown.height(forWidth: bubbleWidth - Self.padding * 2) + attachments.height(forWidth: bubbleWidth - Self.padding * 2)
        let expanded = item?.ui.messageExpanded ?? false
        let body = collapsible && !expanded ? min(full, Self.collapsedHeight) : full
        return (bubbleWidth, body, full)
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        let m = metrics(width)
        let footer: CGFloat = collapsible ? 6 + 24 : 0
        return markerSpace + m.body + footer + Self.padding * 2 + 4 + 24 + 16
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let m = metrics(width)
        let footer: CGFloat = collapsible ? 6 + 24 : 0
        let bubbleHeight = m.body + footer + Self.padding * 2
        let top = markerSpace
        let markerWidth = marker.fittingWidth
        marker.frame = NSRect(x: width - 4 - markerWidth, y: 0, width: markerWidth, height: UserIntentMarkerView.height)
        bubble.frame = NSRect(x: width - m.bubble, y: top, width: m.bubble, height: bubbleHeight)
        let attachmentsHeight = attachments.height(forWidth: m.bubble - Self.padding * 2)
        attachments.frame = NSRect(x: width - m.bubble + Self.padding, y: top + Self.padding, width: m.bubble - Self.padding * 2, height: attachmentsHeight)
        markdown.frame = NSRect(x: Self.padding, y: Self.padding + attachmentsHeight, width: m.bubble - Self.padding * 2, height: m.full - attachmentsHeight)
        let clipped = collapsible && m.body < m.full
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if clipped {
            // `linear-gradient(to bottom, black calc(100% - 1.75rem), transparent)` over the clamped body.
            fadeMask.frame = CGRect(x: 0, y: 0, width: markdown.bounds.width, height: m.full)
            fadeMask.locations = [0, NSNumber(value: Double((m.body - Self.fade) / m.full)), NSNumber(value: Double(m.body / m.full))]
            markdown.layer?.mask = fadeMask
        } else {
            markdown.layer?.mask = nil
        }
        CATransaction.commit()
        bubble.layer?.masksToBounds = true
        let size = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: Self.padding - 4, y: Self.padding + m.body + 6, width: size.width, height: size.height)
        // Hover row: `max-w-[80%] justify-end pe-1 gap-2`, 24px tall under a 4px gap.
        let rowTop = top + bubbleHeight + 4
        let copySize = copyButton.intrinsicContentSize
        copyButton.frame = NSRect(x: width - 4 - copySize.width, y: rowTop, width: copySize.width, height: 24)
        editButton.frame = NSRect(x: copyButton.frame.minX - 28, y: rowTop, width: 24, height: 24)
        let timeWidth = ceil(time.textWidth)
        time.frame = NSRect(x: (editButton.isHidden ? copyButton.frame.minX : editButton.frame.minX) - 8 - timeWidth, y: rowTop + 4, width: timeWidth, height: 16)
    }

    override func hoverChanged() { Self.reveal([time, copyButton, editButton], hovered) }
}

/// `AssistantTimelineRow` (:2745-2793): markdown in `px-1 py-0.5`, then the meta row that shows on
/// hover when this is the turn's final answer. 16px under a final answer, 8px under commentary.
final class AssistantMessageRowView: TimelineRowView {
    private let markdown = MarkdownView(frame: .zero)
    private let empty = LabelView("(empty response)", font: TL.font(14), color: TL.c(\.foreground, 0.8))
    private let meta = AssistantMetaContent()
    private var showMeta = false
    /// `AssistantChangedFilesSection`: the card when the run changed files.
    private lazy var card = ChangedFilesCardView()
    private var cardFiles: (files: [CheckpointFile], expanded: Bool, overrides: [String: Bool])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(markdown)
        empty.lineHeight = TL.relaxed
        addSubview(empty)
        addSubview(meta)
        meta.alphaValue = 0
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .message(let m, let projected, let showMeta, let showCopy, let copyStreaming, let summary) = item.row.kind else { return }
        self.showMeta = showMeta
        if let summary, !summary.files.isEmpty {
            cardFiles = (summary.files, item.ui.filesExpanded, item.ui.folderOverrides)
            if card.superview == nil { addSubview(card) }
            card.model = context.model
            card.configure(summary, allExpanded: item.ui.filesExpanded, overrides: item.ui.folderOverrides)
            card.isHidden = false
        } else {
            cardFiles = nil
            if card.superview != nil { card.isHidden = true }
        }
        let isEmpty = m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !m.streaming
        empty.isHidden = !isEmpty
        markdown.isHidden = isEmpty
        markdown.cwd = context.markdownCwd
        markdown.onOpenFile = context.model?.openFile
        // Diagrams draw once the message stops streaming (`isStreaming={row.message.streaming}`, :2765).
        markdown.diagramsEnabled = !m.streaming
        markdown.document = isEmpty ? MarkdownDocument(blocks: []) : context.document(item.id, m.text, lineBreaks: TL.preservesAssistantLineBreaks(m.text))
        meta.isHidden = !showMeta
        meta.configure(m, projected: projected, showCopy: showCopy, streaming: copyStreaming, now: context.now(), fork: context.forkAction(projected))
        needsLayout = true
    }

    private func bodyHeight(_ width: CGFloat) -> CGFloat {
        empty.isHidden ? markdown.height(forWidth: max(0, width - 8)) : TL.relaxed
    }

    /// The card's height plus its `mt-4`, or 0.
    private var cardSpace: CGFloat {
        guard let cardFiles else { return 0 }
        return 16 + ChangedFilesCardView.height(cardFiles.files, allExpanded: cardFiles.expanded, overrides: cardFiles.overrides)
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        2 + bodyHeight(width) + cardSpace + (showMeta ? 6 + 24 : 0) + 2 + (showMeta ? 16 : 8)
    }

    override func layout() {
        super.layout()
        let body = bodyHeight(bounds.width)
        markdown.frame = NSRect(x: 4, y: 2, width: max(0, bounds.width - 8), height: body)
        empty.frame = NSRect(x: 4, y: 2, width: bounds.width - 8, height: TL.relaxed)
        let cardSpace = self.cardSpace
        if cardSpace > 0 { card.frame = NSRect(x: 4, y: 2 + body + 16, width: max(0, bounds.width - 8), height: cardSpace - 16) }
        meta.frame = NSRect(x: 4, y: 2 + body + cardSpace + 6, width: bounds.width - 8, height: 24)
    }

    override func hoverChanged() { Self.reveal([meta], hovered) }
}

/// `AssistantMessageMeta` (:2860-2912): status pill, copy button, fork button, time; `gap-2`, `text-xs`.
final class AssistantMetaContent: DSView {
    private let pill = FillView()
    private let pillLabel = LabelView("", font: DSFont.mono(10), color: TL.c(\.mutedForeground))
    private let copyButton = Features.copyButton()
    /// `AssistantForkButton` (:2795-2838): `xs ghost`, a 12pt git-fork, "Fork from this response".
    private let forkButton = ButtonView(nil, icon: .gitFork, variant: .ghost, size: .xs)
    private var fork: (() -> Void)?
    private let time = LabelView("", font: TL.tabular(12), color: TL.c(\.mutedForeground))
    private var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pill.border = TL.c(\.border, 0.7)
        pill.radius = 999
        addSubview(pill)
        pillLabel.lineHeight = 14
        pill.addSubview(pillLabel)
        addSubview(copyButton)
        forkButton.iconSize = 12
        forkButton.setAccessibilityLabel("Fork from this response")
        _ = TooltipController.attach(to: forkButton, text: "Fork from this response", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        forkButton.action = { [weak self] in
            guard let self, let fork = self.fork else { return }
            // `disabled={busy}` until the fork settles; the row is rebuilt after it.
            self.forkButton.isEnabled = false
            fork()
        }
        forkButton.isHidden = true
        addSubview(forkButton)
        time.lineHeight = 16
        addSubview(time)
        copyButton.action = { [weak self] in
            guard let self else { return }
            Features.copy(self.text, from: self.copyButton)
        }
    }

    func configure(_ m: ChatMessage, projected: ProjectedTurnItem?, showCopy: Bool, streaming: Bool, now: Date, fork: (() -> Void)? = nil) {
        self.fork = fork
        forkButton.isHidden = fork == nil
        forkButton.isEnabled = true
        text = m.text
        let status = projected?.item.status.rawValue
        pill.isHidden = status == nil || status == "completed"
        pillLabel.text = status ?? ""
        copyButton.isHidden = !TimelineRows.copyState(text: m.text, showCopyButton: showCopy, streaming: streaming).visible
        time.isHidden = m.streaming
        time.text = TL.dayAwareTimestamp(m.updatedAt, now: now)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if !pill.isHidden {
            let w = ceil(pillLabel.textWidth) + 14
            pill.frame = NSRect(x: x, y: 4, width: w, height: 16)
            pillLabel.frame = NSRect(x: 7, y: 1, width: w - 14, height: 14)
            x += w + 8
        }
        if !copyButton.isHidden {
            let size = copyButton.intrinsicContentSize
            copyButton.frame = NSRect(x: x, y: 0, width: size.width, height: 24)
            x += size.width + 8
        }
        if !forkButton.isHidden {
            let size = forkButton.intrinsicContentSize
            forkButton.frame = NSRect(x: x, y: 0, width: size.width, height: 24)
            x += size.width + 8
        }
        time.frame = NSRect(x: x, y: 4, width: ceil(time.textWidth) + 1, height: 16)
    }
}

/// The standalone `assistant-meta` row (:2841-2858): `px-1`, `mt-0.5`, always visible.
final class AssistantMetaRowView: TimelineRowView {
    private let meta = AssistantMetaContent()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(meta)
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .assistantMeta(let m, let projected, let showCopy, let streaming) = item.row.kind else { return }
        meta.configure(m, projected: projected, showCopy: showCopy, streaming: streaming, now: context.now(), fork: context.forkAction(projected))
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 2 + 24 + 16 }

    override func layout() {
        super.layout()
        meta.frame = NSRect(x: 4, y: 2, width: bounds.width - 8, height: 24)
    }
}

/// `ProposedPlanCard` (ProposedPlanCard.tsx:164-243) in `px-1 py-0.5`: a 24px-radius card with the
/// Plan badge and title, the markdown, and Expand plan for long plans (over 900 characters or 20 lines).
final class PlanRowView: TimelineRowView {
    private let card = FillView()
    private let badge = BadgeView("Plan", variant: .secondary)
    private let title = LabelView("", font: TL.font(14, .medium), color: TL.c(\.foreground))
    private let actionsButton = ButtonView(icon: .ellipsis, variant: .outline, size: .iconXs)
    private let markdown = MarkdownView(frame: .zero)
    private let fade = CAGradientLayer()
    private let fadeView = DSView()
    private let toggle = ButtonView("Expand plan", variant: .outline, size: .sm)
    private var collapsible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.radius = 24
        card.fill = TL.c(\.card, 0.7)
        card.border = TL.c(\.border, 0.8)
        addSubview(card)
        title.lineHeight = 20
        actionsButton.iconSize = 16
        actionsButton.setAccessibilityLabel("Plan actions")
        // ponytail: the menu (copy, download, save to workspace) is not built; it arrives with file writes
        for view in [badge, title, actionsButton, markdown, fadeView, toggle] as [NSView] { card.addSubview(view) }
        markdown.bodyColor = TL.c(\.foreground)
        fadeView.layer?.addSublayer(fade)
        toggle.action = { [weak self] in
            guard let self, case .proposedPlan(let p)? = self.item?.row.kind else { return }
            self.context.model?.togglePlan(p.id.rawValue)
        }
    }

    /// `proposedPlanTitle` and `stripDisplayedPlanMarkdown` (packages/shared/src/proposedPlanText.ts).
    static func split(_ markdown: String) -> (title: String, body: String) {
        let heading = /(?m)^\s{0,3}#{1,6}\s+(.+)$/
        let title = markdown.firstMatch(of: heading).map { String($0.1).trimmingCharacters(in: .whitespaces) } ?? ""
        var lines = markdown.replacing(/\s+$/, with: "").components(separatedBy: .newlines)
        if let first = lines.first, first.contains(/^\s{0,3}#{1,6}\s+/) { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if let first = lines.first, let m = first.firstMatch(of: /^\s{0,3}#{1,6}\s+(.+)$/), m.1.trimmingCharacters(in: .whitespaces).lowercased() == "summary" {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        return (title.isEmpty ? "Proposed plan" : title, lines.joined(separator: "\n"))
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .proposedPlan(let plan) = item.row.kind else { return }
        let parts = Self.split(plan.planMarkdown)
        title.text = parts.title
        collapsible = plan.planMarkdown.count > 900 || plan.planMarkdown.split(separator: "\n", omittingEmptySubsequences: false).count > 20
        let collapsed = collapsible && !item.ui.planExpanded
        // ponytail: the collapsed preview is the first 10 body lines; T3's buildCollapsedProposedPlanPreviewMarkdown also closes open fences
        let body = collapsed ? parts.body.components(separatedBy: "\n").prefix(10).joined(separator: "\n") : parts.body
        markdown.cwd = context.markdownCwd
        markdown.onOpenFile = context.model?.openFile
        markdown.document = context.document(item.id + (collapsed ? ":preview" : ""), body, lineBreaks: false)
        toggle.title = item.ui.planExpanded ? "Collapse plan" : "Expand plan"
        toggle.isHidden = !collapsible
        fadeView.isHidden = !collapsed
        needsLayout = true
    }

    private var collapsed: Bool { collapsible && !(item?.ui.planExpanded ?? false) }

    private func bodyHeight(_ width: CGFloat) -> CGFloat {
        let h = markdown.height(forWidth: max(0, width - 8 - 42))
        return collapsed ? min(h, 416) : h
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        // card: 20 + header 24 + 16 + body (+ 16 + 28 button) + 20, border 1 each side; row py-0.5 and pb-4.
        2 + 1 + 20 + 24 + 16 + bodyHeight(width) + (collapsible ? 16 + 28 : 0) + 20 + 1 + 2 + 16
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 8
        let body = bodyHeight(bounds.width)
        let cardHeight = 1 + 20 + 24 + 16 + body + (collapsible ? 16 + 28 : 0) + 20 + 1
        card.frame = NSRect(x: 4, y: 2, width: width, height: cardHeight)
        let inner = width - 42
        let badgeSize = badge.intrinsicContentSize
        badge.frame = NSRect(x: 21, y: 21 + (24 - badgeSize.height) / 2, width: badgeSize.width, height: badgeSize.height)
        actionsButton.frame = NSRect(x: 21 + inner - 24, y: 21, width: 24, height: 24)
        title.frame = NSRect(x: badge.frame.maxX + 8, y: 23, width: max(0, actionsButton.frame.minX - 12 - badge.frame.maxX - 8), height: 20)
        markdown.frame = NSRect(x: 21, y: 61, width: inner, height: markdown.height(forWidth: inner))
        card.layer?.masksToBounds = true
        let bodyBox = NSRect(x: 21, y: 61, width: inner, height: body)
        fadeView.frame = NSRect(x: bodyBox.minX, y: bodyBox.maxY - 96, width: inner, height: 96)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = fadeView.bounds
        fade.colors = resolving { [NSColor.clear, TL.c(\.card, 0.8), TL.c(\.card, 0.95)].map(\.cgColor) }
        fade.locations = [0, 0.5, 1]
        CATransaction.commit()
        // Everything past the clamp is hidden under the card's clip by moving the button over it.
        markdown.layer?.mask = nil
        if collapsed {
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.frame = CGRect(x: 0, y: 0, width: inner, height: body)
            markdown.layer?.mask = mask
        }
        let size = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: 21 + (inner - size.width) / 2, y: bodyBox.maxY + 16, width: size.width, height: 28)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A user message's attachments (MessagesTimeline.tsx:2402-2490): images in a `grid max-w-[210px]
/// grid-cols-2 gap-2` of `aspect-[4/3] rounded-lg border border-border/80 bg-background/70` cells,
/// then files without a chip in the text as `py-1 text-sm` rows with the pierre icon, the name and
/// an eye, each block `mb-2`. Images decode at cell size through the model's loader.
final class UserMessageAttachmentsView: DSView {
    private struct Image { let attachmentId: String; let name: String }
    private var images: [Image] = []
    private var files: [String] = []
    private var cells: [AsyncImageView] = []
    private var rows: [(icon: IconView, label: LabelView, eye: IconView?)] = []
    private weak var model: ThreadViewModel?
    static let gridWidth: CGFloat = 210, gap: CGFloat = 8, rowHeight: CGFloat = 28

    func configure(_ m: ChatMessage, model: ThreadViewModel?) {
        self.model = model
        var images: [Image] = [], files: [String] = []
        // Files with a chip in the text need no row (`chippedAttachmentIds`).
        var chipped = Set<String>()
        if case .array(let records)? = m.context?["records"] {
            let referenced = Set(ComposerContext.referencedIds(m.text))
            for r in records where ["file", "image"].contains(r["kind"]?.stringValue ?? "") && referenced.contains(r["contextId"]?.stringValue ?? "") {
                if let id = r["attachmentId"]?.stringValue { chipped.insert(id) }
            }
        }
        for a in m.attachments {
            let type = a["type"]?.stringValue ?? "", id = a["id"]?.stringValue ?? "", name = a["name"]?.stringValue ?? ""
            if type == "image" {
                if !name.hasPrefix("preview-annotation-") { images.append(Image(attachmentId: id, name: name)) }
            } else if !(type == "file" && chipped.contains(id)) {
                files.append(name)
            }
        }
        guard images.map(\.attachmentId) != self.images.map(\.attachmentId) || files != self.files else { return }
        self.images = images
        self.files = files
        rebuild()
    }

    private func rebuild() {
        cells.forEach { $0.removeFromSuperview() }
        rows.forEach { $0.icon.removeFromSuperview(); $0.label.removeFromSuperview(); $0.eye?.removeFromSuperview() }
        let loader = model?.attachmentImage
        cells = images.enumerated().map { i, image in
            let cell = AsyncImageView()
            cell.layer?.cornerRadius = 10
            cell.layer?.borderWidth = 1
            cell.fallback.font = DSFont.ui(11)
            let id = image.attachmentId
            cell.set(key: id, fallbackText: image.name, loader: loader.map { load in { side in await load(id, side, true) } })
            let click = NSClickGestureRecognizer(target: self, action: #selector(expand(_:)))
            cell.addGestureRecognizer(click)
            cell.setAccessibilityLabel("Preview \(image.name)")
            addSubview(cell)
            return cell
        }
        rows = files.map { name in
            let meta = FileLinkMeta(filePath: name, targetPath: name, workspaceRelativePath: name, basename: name, line: nil, column: nil)
            let (definition, color) = FileChipStyle.icon(for: meta)
            let icon = IconView(definition: definition, size: 16, color: color)
            let label = LabelView(name, font: DSFont.ui(14), color: TL.c(\.foreground))
            label.lineHeight = 20
            [icon, label].forEach(addSubview)
            return (icon, label, nil)
        }
        needsLayout = true
        needsDisplay = true
    }

    @objc private func expand(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let index = cells.firstIndex(where: { $0 === view }), let loader = model?.attachmentImage else { return }
        let items = images.map { image in
            ExpandedImagePreviewView.Item(key: image.attachmentId, name: image.name) { side in await loader(image.attachmentId, side, false) }
        }
        model?.onExpandImage?(items, index)
    }

    private var cellSize: CGSize {
        let w = (Self.gridWidth - Self.gap) / 2
        return CGSize(width: w, height: w * 3 / 4)
    }

    /// The widest block: the 210pt grid, or the longest file row.
    var naturalWidth: CGFloat {
        let fileWidth = rows.map { 16 + 8 + ceil($0.label.textWidth) }.max() ?? 0
        return max(images.isEmpty ? 0 : Self.gridWidth, fileWidth)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        if !images.isEmpty {
            let gridRows = CGFloat((images.count + 1) / 2)
            h += gridRows * cellSize.height + (gridRows - 1) * Self.gap + 8
        }
        if !files.isEmpty { h += CGFloat(files.count) * Self.rowHeight + CGFloat(files.count - 1) * 4 + 8 }
        return h
    }

    override func updateLayer() {
        for cell in cells {
            cell.layer?.backgroundColor = TL.c(\.background).withAlphaComponent(0.7).cgColor(in: self)
            cell.layer?.borderColor = TL.c(\.border).withAlphaComponent(0.8).cgColor(in: self)
        }
    }

    override func layout() {
        super.layout()
        let size = cellSize
        let gridWidth = min(Self.gridWidth, bounds.width)
        let cw = gridWidth == Self.gridWidth ? size.width : (gridWidth - Self.gap) / 2
        let ch = cw * 3 / 4
        for (i, cell) in cells.enumerated() {
            cell.frame = NSRect(x: CGFloat(i % 2) * (cw + Self.gap), y: CGFloat(i / 2) * (ch + Self.gap), width: cw, height: ch)
        }
        var y: CGFloat = images.isEmpty ? 0 : CGFloat((images.count + 1) / 2) * (ch + Self.gap) - Self.gap + 8
        for row in rows {
            row.icon.frame = NSRect(x: 0, y: y + 6, width: 16, height: 16)
            row.label.frame = NSRect(x: 24, y: y + 4, width: max(0, bounds.width - 24), height: 20)
            y += Self.rowHeight + 4
        }
    }
}
