import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `TurnFoldTimelineRow` (MessagesTimeline.tsx:2699-2721): "Worked for 10s" and a chevron over a
/// hairline; `pt-1 pb-2`, border, then the wrapper's `pb-1.5`. Hover turns the label foreground.
final class TurnFoldRowView: TimelineRowView {
    private let label = LabelView("", font: TL.tabular(14), color: TL.c(\.mutedForeground))
    /// `MorphIcon` chevron-right to chevron-down (:2712): the morph is a quarter turn on a spring.
    private let chevron = IconView(name: .chevronRight, size: 14)
    private let time = LabelView("", font: TL.tabular(12), color: TL.c(\.mutedForeground))
    private let rule = FillView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = TL.relaxed
        time.lineHeight = 16
        time.alphaValue = 0
        rule.fill = TL.c(\.border, 0.6)
        for v in [label, chevron, time, rule] as [NSView] { addSubview(v) }
        hoverChanged()
        setAccessibilityRole(.button)
        onClick = { [weak self] in
            guard let self, case .turnFold(let runId, _, _)? = self.item?.row.kind else { return }
            self.context.disclosure(self.item?.id)
            self.context.model?.toggleRun(runId)
        }
    }

    override func configure(_ item: TimelineItem) {
        let sameRow = self.item?.id == item.id
        super.configure(item)
        guard case .turnFold(_, let text, let expanded) = item.row.kind else { return }
        label.text = text
        chevron.setRotation(expanded ? 90 : 0, motion: sameRow ? .morph : .none)
        time.text = TL.dayAwareTimestamp(item.row.createdAt, now: context.now())
        setAccessibilityLabel(text)
        setAccessibilityExpanded(expanded)
        needsLayout = true
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 4 + TL.relaxed + 8 + 1 + 6 }

    override func layout() {
        super.layout()
        let w = label.textWidth
        label.frame = NSRect(x: 4, y: 4, width: ceil(w) + 1, height: TL.relaxed)
        chevron.frame = NSRect(x: 4 + w + 4, y: 4 + (TL.relaxed - 14) / 2, width: 14, height: 14)
        let tw = ceil(time.textWidth)
        time.frame = NSRect(x: bounds.width - 2 - tw, y: 4 + (TL.relaxed - 16) / 2, width: tw, height: 16)
        rule.frame = NSRect(x: 0, y: TL.snap(4 + TL.relaxed + 8), width: bounds.width, height: 1)
    }

    override var hoverTransitions: Motion.Transition { .colors } // MessagesTimeline.tsx:2709

    override func hoverChanged() {
        let color = hovered ? TL.c(\.foreground) : TL.c(\.mutedForeground)
        label.color = color
        chevron.strokeColor = color
        time.alphaValue = hovered ? 1 : 0
    }
}

/// `AttemptFoldTimelineRow` (:2723-2743): a bordered full-width button for a superseded attempt.
final class AttemptFoldRowView: TimelineRowView {
    private let box = FillView()
    /// `MorphIcon` chevron-right to chevron-down (:2735-2738), a quarter turn on a spring.
    private let chevron = IconView(name: .chevronRight, size: 14, strokeColor: TL.c(\.mutedForeground))
    private let label = LabelView("", font: TL.font(12, .medium), color: TL.c(\.foreground, 0.8))
    private let note = LabelView("Partial output retained", font: TL.font(11), color: TL.c(\.mutedForeground))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        box.radius = 8
        box.border = TL.c(\.border, 0.6)
        addSubview(box)
        label.lineHeight = 16
        note.lineHeight = 16
        for v in [chevron, label, note] as [NSView] { box.addSubview(v) }
        hoverChanged()
        setAccessibilityRole(.button)
        onClick = { [weak self] in
            guard let self, case .attemptFold(_, let attemptId, _, _)? = self.item?.row.kind else { return }
            self.context.disclosure(self.item?.id)
            self.context.model?.toggleAttempt(attemptId)
        }
    }

    override func configure(_ item: TimelineItem) {
        let sameRow = self.item?.id == item.id
        super.configure(item)
        guard case .attemptFold(_, _, let text, let expanded) = item.row.kind else { return }
        label.text = text
        chevron.setRotation(expanded ? 90 : 0, motion: sameRow ? .morph : .none)
        setAccessibilityExpanded(expanded)
        needsLayout = true
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 34 + 8 }

    override func layout() {
        super.layout()
        box.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 34)
        chevron.frame = NSRect(x: 11, y: 10, width: 14, height: 14)
        let lw = ceil(label.textWidth)
        label.frame = NSRect(x: 33, y: 9, width: lw, height: 16)
        note.frame = NSRect(x: 33 + lw + 8, y: 9, width: max(0, bounds.width - 33 - lw - 8 - 11), height: 16)
    }

    override var hoverTransitions: Motion.Transition { .colors } // MessagesTimeline.tsx:2733

    override func hoverChanged() {
        box.fill = TL.c(\.muted, hovered ? 0.35 : 0.2)
    }
}

/// `ContextCompactionTimelineRow` (:2111-2143): a rule, the minimize icon and label, a rule.
final class CompactionRowView: TimelineRowView {
    private let left = FillView(), right = FillView()
    private let icon = IconView(name: .minimize2, size: 12, strokeColor: TL.c(\.mutedForeground))
    private let label = ShineLabelView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for r in [left, right] { r.fill = TL.c(\.border, 0.7); addSubview(r) }
        label.font = TL.font(12)
        label.lineHeight = 16
        label.base.color = TL.c(\.mutedForeground)
        label.style = .focus
        addSubview(icon)
        addSubview(label)
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .contextCompaction(let text, let active) = item.row.kind else { return }
        label.text = text
        label.shining = active
        needsLayout = true
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 4 + 16 + 4 + 16 }

    override func layout() {
        super.layout()
        let lw = ceil(label.textWidth)
        let cluster = 12 + 6 + lw
        let x = (bounds.width - cluster) / 2
        left.frame = NSRect(x: 0, y: 12, width: max(0, x - 12), height: 1)
        right.frame = NSRect(x: x + cluster + 12, y: 12, width: max(0, bounds.width - x - cluster - 12), height: 1)
        icon.frame = NSRect(x: x, y: 6, width: 12, height: 12)
        label.frame = NSRect(x: x + 18, y: 4, width: lw, height: 16)
    }
}

/// Event rows (`V2EventTimelineRow`, :3079-3270, and `V2LifecycleRow`): lifecycle events as a
/// centered divider pill (`TimelineSystemDivider`), the rest as a tinted card. 8px under either.
/// Rows about another thread open it (`onOpenThread`): a fork's pill, a created thread's "Open chat"
/// (a work-log line, or a bordered card in the turn's resource summary) and a subagent card.
final class EventRowView: TimelineRowView {
    enum Tone { case muted, danger, warning, success }
    private enum Look { case divider, card, line, createdCard }

    private var look = Look.card
    private var tone = Tone.muted
    private let leftRule = FillView(), rightRule = FillView()
    private let card = FillView()
    /// The divider's button when it opens a thread (`rounded-full border border-border/70 bg-background`).
    private let pill = TimelineParentLinkPill()
    /// A handoff row draws its own divider with the models.
    private var handoff: HandoffDividerView?
    private var icon = IconView(name: .wrench, size: 14)
    private var iconName = IconName.wrench
    private var iconSize: CGFloat = 14
    private let label = LabelView("", font: TL.font(12, .medium))
    private let detailInline = LabelView("", font: TL.font(11))
    private let detail = TextBlockView("", font: TL.font(12), lineHeight: 12 * 1.625, color: TL.c(\.mutedForeground))
    /// The created card's `size-9 rounded-lg bg-muted/60` icon box.
    private let iconBox = FillView()
    /// "Open chat": an `InlineButton` on the line, an outline `xs` button on the card.
    private let openInline = ThreadStatusLineAction()
    private let openButton = ButtonView("Open chat", variant: .outline, size: .xs)
    private let chevron = IconView(name: .chevronRight, size: 14)
    /// The thread this row opens, and the pill's tooltip.
    private var target: ThreadId?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for r in [leftRule, rightRule] { r.fill = TL.c(\.border, 0.7); addSubview(r) }
        card.radius = 10
        addSubview(card)
        iconBox.radius = 8
        iconBox.fill = TL.c(\.muted, 0.6)
        addSubview(iconBox)
        addSubview(pill)
        addSubview(icon)
        label.lineHeight = 16
        detailInline.lineHeight = 16
        addSubview(label)
        addSubview(detailInline)
        addSubview(detail)
        openInline.label.font = TL.font(14, .medium)
        openInline.label.lineHeight = 24
        openInline.tone = .foreground
        openInline.label.text = "Open chat"
        for v in [openInline, openButton, chevron] as [NSView] { addSubview(v) }
        chevron.strokeColor = TL.c(\.mutedForeground, 0.6)
        let open: @MainActor () -> Void = { [weak self] in
            guard let self, let target = self.target else { return }
            self.context.model?.onOpenThread?(target)
        }
        pill.action = open
        openInline.action = open
        openButton.action = open
    }

    /// `run_interrupt_result`, fork, handoff, compaction and created threads read as dividers;
    /// errors and the rest as cards. Subagents use SubagentCardRowView.
    private static func describe(_ p: ProjectedTurnItem, summary: Bool) -> (Look, Tone, IconName, String, String?) {
        let item = p.item
        switch item.type {
        case .runInterruptResult: return (.divider, .danger, .x, "Run interrupted", p.string("message"))
        case .fork:
            let fromRun = item["source"]?["type"]?.stringValue == "run"
            return (.divider, .muted, .gitFork, fromRun ? "Forked from conversation" : "Conversation fork", nil)
        case .handoff: return (.divider, .muted, .arrowRightLeft, "Context handoff", nil)
        case .compaction: return (.divider, .muted, .minus, compactionLabel(item.status), p.string("summary") ?? compactionTokens(item))
        case .threadCreated:
            // V2LifecycleRow.tsx:171-209: a bordered card in the resource summary, else a work-log line.
            let title = p.string("title") ?? item.title
            return summary ? (.createdCard, .muted, .messageSquare, title ?? "Created thread", nil)
                : (.line, .muted, .brandT3Wordmark, "Created thread" + (title.map { " · \($0)" } ?? ""), nil)
        case .secretRequest: return (.card, .muted, .lock, item.title ?? "Secret request", nil)
        case .error:
            let (label, detail) = WorkLog.providerErrorPresentation(item)
            let tone: Tone = item.status.rawValue == "completed" ? .success : item.status.rawValue == "running" ? .warning : .danger
            return (.card, tone, .circleAlert, label, detail)
        default:
            return (.card, .muted, .wrench, item.title ?? item.type.rawValue.replacingOccurrences(of: "_", with: " "), nil)
        }
    }

    /// The compaction divider's label by status (V2LifecycleRow.tsx:110-117).
    nonisolated static func compactionLabel(_ status: TurnItemStatus) -> String {
        switch status {
        case .failed: "Context compaction failed"
        case .cancelled, .interrupted: "Context compaction stopped"
        case .pending, .running, .waiting: "Compacting context"
        default: "Context compacted"
        }
    }

    /// `tokenDetail` (V2LifecycleRow.tsx:106-109): the raw counts, "?" for a missing one, as JS prints numbers.
    nonisolated static func compactionTokens(_ item: TurnItem) -> String? {
        let before = item["beforeTokenCount"]?.doubleValue, after = item["afterTokenCount"]?.doubleValue
        guard before != nil || after != nil else { return nil }
        func js(_ v: Double?) -> String {
            guard let v else { return "?" }
            return v == v.rounded() && abs(v) < 1e21 ? String(Int64(v)) : String(v)
        }
        return "\(js(before)) → \(js(after)) tokens"
    }

    /// The thread a row opens (V2LifecycleRow.tsx:159-231): a fork's source conversation (or the fork),
    /// a created thread, a subagent's child thread.
    static func openTarget(_ p: ProjectedTurnItem) -> (ThreadId, String)? {
        let item = p.item
        switch item.type {
        case .fork:
            let source = item["source"]
            if source?["type"]?.stringValue == "run" {
                return source?["threadId"]?.stringValue.map { (ThreadId($0), "Open source conversation") }
            }
            return p.string("targetThreadId").map { (ThreadId($0), "Open fork") }
        case .threadCreated: return p.string("targetThreadId").map { (ThreadId($0), "Open chat") }
        case .subagent: return p.string("childThreadId").map { (ThreadId($0), "Open subagent thread") }
        default: return nil
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .event(let p, _, let summary) = item.row.kind else { return }
        let (look, tone, iconName, text, detailText) = Self.describe(p, summary: summary)
        self.look = look
        self.tone = tone
        let opens = Self.openTarget(p)
        target = opens?.0
        let size: CGFloat = switch look { case .divider: 12; case .line, .createdCard: 16; case .card: 14 }
        if iconName != self.iconName || size != iconSize {
            icon.removeFromSuperview()
            icon = IconView(name: iconName, size: size)
            self.iconName = iconName
            iconSize = size
            addSubview(icon)
        }
        let toneColor: NSColor = switch tone {
        case .danger: TL.c(\.destructive)
        case .warning: TL.c(\.warning)
        case .success: TL.c(\.success)
        case .muted: TL.c(\.mutedForeground)
        }
        let divider = look == .divider
        leftRule.isHidden = !divider
        rightRule.isHidden = !divider
        pill.isHidden = !divider || target == nil
        pill.setAccessibilityLabel(opens?.1)
        pill.toolTip = divider ? opens?.1 : nil
        card.isHidden = divider || look == .line
        iconBox.isHidden = look != .createdCard
        openInline.isHidden = look != .line || target == nil
        openButton.isHidden = look != .createdCard || target == nil
        let subagentLink = look == .card && p.item.type == .subagent && target != nil
        chevron.isHidden = !subagentLink
        onClick = subagentLink ? { [weak self] in
            guard let self, let target = self.target else { return }
            self.context.model?.onOpenThread?(target)
        } : nil
        setAccessibilityRole(subagentLink ? .button : nil)
        setAccessibilityLabel(subagentLink ? "Open \(p.item.title ?? "subagent")" : nil)
        detail.isHidden = divider || look == .line || look == .createdCard || (detailText ?? "").isEmpty
        detailInline.isHidden = !divider || (detailText ?? "").isEmpty
        label.text = text
        // The handoff divider names its models (V2LifecycleRow.tsx:127-135).
        if p.item.type == .handoff {
            if handoff == nil { let v = HandoffDividerView(); addSubview(v); handoff = v }
            handoff?.configure(HandoffEndpoints.resolve(p.item, runs: context.model?.projection?.runs ?? []),
                               providers: context.model?.providers ?? [], failed: p.item.status == .failed)
        }
        handoff?.isHidden = p.item.type != .handoff
        for v in [leftRule, rightRule, icon, label] as [NSView] where p.item.type == .handoff { v.isHidden = true }
        if p.item.type != .handoff { icon.isHidden = false; label.isHidden = false }
        switch look {
        case .divider:
            label.font = TL.font(11, .medium)
            label.color = toneColor
            detailInline.text = "· " + (detailText ?? "")
            detailInline.color = toneColor.withAlphaComponent(0.7)
            icon.strokeColor = toneColor
        case .line:
            // `WorkLogRow`: `text-sm text-secondary-label`, the wordmark in `text-icon-muted`.
            label.font = TL.font(14)
            label.lineHeight = 24
            label.color = TL.c(\.secondaryLabel)
            icon.strokeColor = WorkIcons.muted
        case .createdCard:
            label.font = TL.font(14, .medium)
            label.lineHeight = 20
            label.color = TL.c(\.foreground)
            icon.strokeColor = TL.c(\.secondaryLabel)
            card.border = TL.c(\.border, 0.6)
            card.fill = .clear
        case .card:
            label.font = TL.font(12, .medium)
            label.lineHeight = 16
            label.color = TL.c(\.foreground, 0.9)
            detail.text = detailText ?? ""
            icon.strokeColor = tone == .muted ? TL.c(\.mutedForeground) : toneColor
            switch tone {
            case .danger: card.border = TL.c(\.destructive, 0.25); card.fill = TL.c(\.destructive, 0.05)
            case .warning: card.border = TL.c(\.warning, 0.25); card.fill = TL.c(\.warning, 0.05)
            case .success: card.border = TL.c(\.success, 0.2); card.fill = TL.c(\.success, 0.05)
            case .muted: card.border = TL.c(\.border, 0.6); card.fill = hovered && subagentLink ? TL.c(\.accent, 0.2) : TL.c(\.card, 0.3)
            }
        }
        if look != .line { label.lineHeight = look == .createdCard ? 20 : 16 }
        needsLayout = true
    }

    // `transition-colors hover:bg-accent/20` on the card, `group-hover/subagent:text-foreground` on its
    // chevron (V2LifecycleRow.tsx:487,512).
    override var hoverTransitions: Motion.Transition { .colors }

    override func hoverChanged() {
        guard look == .card, tone == .muted, onClick != nil else { return }
        card.fill = hovered ? TL.c(\.accent, 0.2) : TL.c(\.card, 0.3)
        chevron.strokeColor = hovered ? TL.c(\.foreground) : TL.c(\.mutedForeground, 0.6)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !pill.isHidden, pill.frame.contains(local) { return pill }
        return super.hitTest(point)
    }

    private func detailHeight(_ width: CGFloat) -> CGFloat {
        detail.isHidden ? 0 : 4 + detail.height(forWidth: max(0, width - 48))
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        switch look {
        case .divider: 8 + 24 + 8 + 8
        // `py-0.5` around the 24pt line, then the block's `pb-2`.
        case .line: 2 + 24 + 2 + 8
        // `p-3` around the `size-9` box and a 1pt border, then 8 under.
        case .createdCard: 1 + 12 + 36 + 12 + 1 + 8
        case .card: 1 + 8 + 16 + detailHeight(width) + 8 + 1 + 8
        }
    }

    override func layout() {
        super.layout()
        switch look {
        case .divider:
            // `gap-1.5 rounded-full px-2 py-1`, max 320px, centered between two rules with `gap-2`; with an
            // action the pill is a bordered button with `px-2.5`.
            handoff?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: HandoffDividerView.height)
            let pad: CGFloat = pill.isHidden ? 8 : 11
            let lw = ceil(label.textWidth), dw = detailInline.isHidden ? 0 : ceil(detailInline.textWidth) + 4
            let pw = min(320, pad + 12 + 6 + lw + dw + pad)
            let x = ((bounds.width - pw) / 2).rounded()
            leftRule.frame = NSRect(x: 0, y: 20, width: max(0, x - 8), height: 1)
            rightRule.frame = NSRect(x: x + pw + 8, y: 20, width: max(0, bounds.width - x - pw - 8), height: 1)
            pill.frame = NSRect(x: x, y: 7, width: pw, height: 26)
            icon.frame = NSRect(x: x + pad, y: 14, width: 12, height: 12)
            label.frame = NSRect(x: x + pad + 18, y: 12, width: min(lw, pw - pad * 2 - 18), height: 16)
            detailInline.frame = NSRect(x: label.frame.maxX + 4, y: 12, width: max(0, x + pw - pad - label.frame.maxX - 4), height: 16)
        case .line:
            icon.frame = NSRect(x: 6, y: 6, width: 16, height: 16)
            let bw = openInline.isHidden ? 0 : openInline.preferredWidth
            openInline.frame = NSRect(x: bounds.width - 2 - bw, y: 2, width: bw, height: 24)
            let right = openInline.isHidden ? bounds.width - 2 : openInline.frame.minX - 6
            label.frame = NSRect(x: 32, y: 2, width: max(0, right - 32), height: 24)
        case .createdCard:
            card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1 + 12 + 36 + 12 + 1)
            iconBox.frame = NSRect(x: 13, y: 13, width: 36, height: 36)
            icon.frame = NSRect(x: 13 + 10, y: 13 + 10, width: 16, height: 16)
            let bs = openButton.intrinsicContentSize
            openButton.frame = NSRect(x: bounds.width - 13 - bs.width, y: 13 + (36 - bs.height) / 2, width: bs.width, height: bs.height)
            let right = openButton.isHidden ? bounds.width - 13 : openButton.frame.minX - 12
            label.frame = NSRect(x: 13 + 36 + 12, y: 13 + 8, width: max(0, right - 61), height: 20)
        case .card:
            let dh = detailHeight(bounds.width)
            card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1 + 8 + 16 + dh + 8 + 1)
            icon.frame = NSRect(x: 13, y: 11, width: 14, height: 14)
            let right: CGFloat = chevron.isHidden ? 13 : 13 + 14 + 8
            chevron.frame = NSRect(x: bounds.width - 13 - 14, y: 11, width: 14, height: 14)
            label.frame = NSRect(x: 35, y: 9, width: bounds.width - 35 - right, height: 16)
            detail.frame = NSRect(x: 35, y: 9 + 16 + 4, width: max(0, bounds.width - 35 - right), height: max(0, dh - 4))
        }
    }
}
