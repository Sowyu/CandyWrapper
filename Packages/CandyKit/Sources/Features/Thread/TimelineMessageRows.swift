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
    NSPasteboard.general.setString(text, forType: .string)
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

/// `UserTimelineRow` (MessagesTimeline.tsx:2198-2560): a right-aligned bubble at most 80% of the
/// lane, then a hover row with the time and a copy button that always keeps its 24px.
final class UserMessageRowView: TimelineRowView {
    static let padding: CGFloat = 12
    static let collapsedHeight: CGFloat = 176
    static let fade: CGFloat = 28

    private let bubble = FillView()
    private let markdown = MarkdownView(frame: .zero)
    private let toggle = ButtonView("Show full message", variant: .ghostMuted, size: .xs)
    private let time = LabelView("", font: TL.tabular(12), color: TL.c(\.mutedForeground))
    private let copyButton = Features.copyButton()
    private let fadeMask = CAGradientLayer()
    private var text = ""
    private var collapsible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.fill = TL.c(\.messageSurface)
        bubble.radius = 18
        addSubview(bubble)
        // `text-foreground` on the bubble, where assistant markdown sits at 80%.
        markdown.bodyColor = TL.c(\.foreground)
        bubble.addSubview(markdown)
        bubble.addSubview(toggle)
        time.lineHeight = 16
        addSubview(time)
        addSubview(copyButton)
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
        markdown.document = context.document(item.id, m.text, lineBreaks: true)
        collapsible = shouldCollapseUserMessage(m.text)
        toggle.title = item.ui.messageExpanded ? "Show less" : "Show full message"
        toggle.isHidden = !collapsible
        time.text = TL.dayAwareTimestamp(m.createdAt, now: context.now())
        time.toolTip = nil
        needsLayout = true
    }

    private func metrics(_ width: CGFloat) -> (bubble: CGFloat, body: CGFloat, full: CGFloat) {
        let maxBubble = width * 0.8
        let inner = maxBubble - Self.padding * 2
        // `fit-content`: the max-content width (unwrapped) if it fits, else the full 80%.
        let natural = markdown.layout(forWidth: 100_000).contentWidth
        var bubbleWidth = natural > inner ? maxBubble : min(maxBubble, ceil(natural * 64) / 64 + Self.padding * 2)
        if collapsible { bubbleWidth = max(bubbleWidth, min(maxBubble, toggle.intrinsicContentSize.width - 4 + Self.padding * 2)) }
        let full = markdown.height(forWidth: bubbleWidth - Self.padding * 2)
        let expanded = item?.ui.messageExpanded ?? false
        let body = collapsible && !expanded ? min(full, Self.collapsedHeight) : full
        return (bubbleWidth, body, full)
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        let m = metrics(width)
        let footer: CGFloat = collapsible ? 6 + 24 : 0
        return m.body + footer + Self.padding * 2 + 4 + 24 + 16
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let m = metrics(width)
        let footer: CGFloat = collapsible ? 6 + 24 : 0
        let bubbleHeight = m.body + footer + Self.padding * 2
        bubble.frame = NSRect(x: width - m.bubble, y: 0, width: m.bubble, height: bubbleHeight)
        markdown.frame = NSRect(x: Self.padding, y: Self.padding, width: m.bubble - Self.padding * 2, height: m.full)
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
        let rowTop = bubbleHeight + 4
        let copySize = copyButton.intrinsicContentSize
        copyButton.frame = NSRect(x: width - 4 - copySize.width, y: rowTop, width: copySize.width, height: 24)
        let timeWidth = ceil(time.textWidth)
        time.frame = NSRect(x: copyButton.frame.minX - 8 - timeWidth, y: rowTop + 4, width: timeWidth, height: 16)
    }

    override func hoverChanged() { Self.reveal([time, copyButton], hovered) }
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
        markdown.document = isEmpty ? MarkdownDocument(blocks: []) : context.document(item.id, m.text, lineBreaks: TL.preservesAssistantLineBreaks(m.text))
        meta.isHidden = !showMeta
        meta.configure(m, projected: projected, showCopy: showCopy, streaming: copyStreaming, now: context.now())
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

/// `AssistantMessageMeta` (:2860-2912): status pill, copy button, time; `gap-2`, `text-xs`.
final class AssistantMetaContent: DSView {
    private let pill = FillView()
    private let pillLabel = LabelView("", font: DSFont.mono(10), color: TL.c(\.mutedForeground))
    private let copyButton = Features.copyButton()
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
        time.lineHeight = 16
        addSubview(time)
        copyButton.action = { [weak self] in
            guard let self else { return }
            Features.copy(self.text, from: self.copyButton)
        }
    }

    func configure(_ m: ChatMessage, projected: ProjectedTurnItem?, showCopy: Bool, streaming: Bool, now: Date) {
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
        meta.configure(m, projected: projected, showCopy: showCopy, streaming: streaming, now: context.now())
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
