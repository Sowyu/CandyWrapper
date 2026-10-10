import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `TurnFoldTimelineRow` (MessagesTimeline.tsx:2699-2721): "Worked for 10s" and a chevron over a
/// hairline; `pt-1 pb-2`, border, then the wrapper's `pb-1.5`. Hover turns the label foreground.
final class TurnFoldRowView: TimelineRowView {
    private let label = LabelView("", font: TL.tabular(14), color: TL.c(\.mutedForeground))
    private let chevron = IconView(name: .chevronRight, size: 14)
    private let chevronOpen = IconView(name: .chevronDown, size: 14)
    private let time = LabelView("", font: TL.tabular(12), color: TL.c(\.mutedForeground))
    private let rule = FillView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = TL.relaxed
        time.lineHeight = 16
        time.alphaValue = 0
        rule.fill = TL.c(\.border, 0.6)
        for v in [label, chevron, chevronOpen, time, rule] as [NSView] { addSubview(v) }
        hoverChanged()
        setAccessibilityRole(.button)
        onClick = { [weak self] in
            guard let self, case .turnFold(let runId, _, _)? = self.item?.row.kind else { return }
            self.context.model?.toggleRun(runId)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .turnFold(_, let text, let expanded) = item.row.kind else { return }
        label.text = text
        chevron.isHidden = expanded
        chevronOpen.isHidden = !expanded
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
        chevronOpen.frame = chevron.frame
        let tw = ceil(time.textWidth)
        time.frame = NSRect(x: bounds.width - 2 - tw, y: 4 + (TL.relaxed - 16) / 2, width: tw, height: 16)
        rule.frame = NSRect(x: 0, y: TL.snap(4 + TL.relaxed + 8), width: bounds.width, height: 1)
    }

    override func hoverChanged() {
        let color = hovered ? TL.c(\.foreground) : TL.c(\.mutedForeground)
        label.color = color
        chevron.strokeColor = color
        chevronOpen.strokeColor = color
        time.alphaValue = hovered ? 1 : 0
    }
}

/// `AttemptFoldTimelineRow` (:2723-2743): a bordered full-width button for a superseded attempt.
final class AttemptFoldRowView: TimelineRowView {
    private let box = FillView()
    private let chevron = IconView(name: .chevronRight, size: 14, strokeColor: TL.c(\.mutedForeground))
    private let chevronOpen = IconView(name: .chevronDown, size: 14, strokeColor: TL.c(\.mutedForeground))
    private let label = LabelView("", font: TL.font(12, .medium), color: TL.c(\.foreground, 0.8))
    private let note = LabelView("Partial output retained", font: TL.font(11), color: TL.c(\.mutedForeground))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        box.radius = 8
        box.border = TL.c(\.border, 0.6)
        addSubview(box)
        label.lineHeight = 16
        note.lineHeight = 16
        for v in [chevron, chevronOpen, label, note] as [NSView] { box.addSubview(v) }
        hoverChanged()
        setAccessibilityRole(.button)
        onClick = { [weak self] in
            guard let self, case .attemptFold(_, let attemptId, _, _)? = self.item?.row.kind else { return }
            self.context.model?.toggleAttempt(attemptId)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .attemptFold(_, _, let text, let expanded) = item.row.kind else { return }
        label.text = text
        chevron.isHidden = expanded
        chevronOpen.isHidden = !expanded
        setAccessibilityExpanded(expanded)
        needsLayout = true
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 34 + 8 }

    override func layout() {
        super.layout()
        box.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 34)
        chevron.frame = NSRect(x: 11, y: 10, width: 14, height: 14)
        chevronOpen.frame = chevron.frame
        let lw = ceil(label.textWidth)
        label.frame = NSRect(x: 33, y: 9, width: lw, height: 16)
        note.frame = NSRect(x: 33 + lw + 8, y: 9, width: max(0, bounds.width - 33 - lw - 8 - 11), height: 16)
    }

    override func hoverChanged() {
        // ponytail: the fill swaps instead of T3's 150ms transition
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
        label.base.font = TL.font(12)
        label.base.lineHeight = 16
        label.base.color = TL.c(\.mutedForeground)
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
final class EventRowView: TimelineRowView {
    enum Tone { case muted, danger, warning, success }
    private enum Look { case divider, card }

    private var look = Look.card
    private var tone = Tone.muted
    private let leftRule = FillView(), rightRule = FillView()
    private let card = FillView()
    private var icon = IconView(name: .wrench, size: 14)
    private var iconName = IconName.wrench
    private let label = LabelView("", font: TL.font(12, .medium))
    private let detailInline = LabelView("", font: TL.font(11))
    private let detail = TextBlockView("", font: TL.font(12), lineHeight: 12 * 1.625, color: TL.c(\.mutedForeground))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for r in [leftRule, rightRule] { r.fill = TL.c(\.border, 0.7); addSubview(r) }
        card.radius = 10
        addSubview(card)
        addSubview(icon)
        label.lineHeight = 16
        detailInline.lineHeight = 16
        addSubview(label)
        addSubview(detailInline)
        addSubview(detail)
    }

    /// `run_interrupt_result`, fork, handoff, compaction and created threads read as dividers;
    /// subagents, errors and the rest as cards (G-timeline-data.md 3.8).
    private static func describe(_ p: ProjectedTurnItem, summary: Bool) -> (Look, Tone, IconName, String, String?) {
        let item = p.item
        switch item.type {
        case .runInterruptResult: return (.divider, .danger, .x, "Run interrupted", p.string("message"))
        case .fork:
            let fromRun = item["source"]?["type"]?.stringValue == "run"
            return (.divider, .muted, .gitFork, fromRun ? "Forked from conversation" : "Conversation fork", nil)
        case .handoff: return (.divider, .muted, .arrowRightLeft, "Context handoff", nil)
        case .compaction: return (.divider, .muted, .minus, "Context compacted", p.string("summary"))
        case .threadCreated:
            let title = p.string("title") ?? item.title
            return summary ? (.card, .muted, .messageSquare, title ?? "Created thread", nil)
                : (.divider, .muted, .messageSquare, "Created thread", title)
        case .subagent:
            let status = switch item.status.rawValue {
            case "pending": "Queued"
            case "running": "Running"
            case "waiting": "Waiting"
            case "idle": "Idle · resumable"
            case "completed": "Completed"
            case "failed": "Failed"
            default: "Stopped"
            }
            let detail = (p.string("result") ?? p.string("progress")).map { $0.replacingOccurrences(of: "`", with: "") }
            return (.card, item.status.rawValue == "failed" ? .danger : .muted, .bot, "\(item.title ?? "Subagent") · \(status)", detail)
        case .secretRequest: return (.card, .muted, .lock, item.title ?? "Secret request", nil)
        case .error:
            let (label, detail) = WorkLog.providerErrorPresentation(item)
            let tone: Tone = item.status.rawValue == "completed" ? .success : item.status.rawValue == "running" ? .warning : .danger
            return (.card, tone, .circleAlert, label, detail)
        default:
            return (.card, .muted, .wrench, item.title ?? item.type.rawValue.replacingOccurrences(of: "_", with: " "), nil)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .event(let p, _, let summary) = item.row.kind else { return }
        let (look, tone, iconName, text, detailText) = Self.describe(p, summary: summary)
        self.look = look
        self.tone = tone
        if iconName != self.iconName {
            icon.removeFromSuperview()
            icon = IconView(name: iconName, size: look == .divider ? 12 : 14)
            self.iconName = iconName
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
        card.isHidden = divider
        detail.isHidden = divider || (detailText ?? "").isEmpty
        detailInline.isHidden = !divider || (detailText ?? "").isEmpty
        label.text = text
        if divider {
            label.font = TL.font(11, .medium)
            label.color = toneColor
            detailInline.text = "· " + (detailText ?? "")
            detailInline.color = toneColor.withAlphaComponent(0.7)
            icon.strokeColor = toneColor
        } else {
            label.font = TL.font(12, .medium)
            label.color = TL.c(\.foreground, 0.9)
            detail.text = detailText ?? ""
            icon.strokeColor = tone == .muted ? TL.c(\.mutedForeground) : toneColor
            switch tone {
            case .danger: card.border = TL.c(\.destructive, 0.25); card.fill = TL.c(\.destructive, 0.05)
            case .warning: card.border = TL.c(\.warning, 0.25); card.fill = TL.c(\.warning, 0.05)
            case .success: card.border = TL.c(\.success, 0.2); card.fill = TL.c(\.success, 0.05)
            case .muted: card.border = TL.c(\.border, 0.6); card.fill = TL.c(\.card, 0.3)
            }
        }
        needsLayout = true
    }

    private func detailHeight(_ width: CGFloat) -> CGFloat {
        detail.isHidden ? 0 : 4 + detail.height(forWidth: max(0, width - 48))
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        look == .divider ? 8 + 24 + 8 + 8 : 1 + 8 + 16 + detailHeight(width) + 8 + 1 + 8
    }

    override func layout() {
        super.layout()
        if look == .divider {
            // `gap-1.5 rounded-full px-2 py-1`, max 320px, centered between two rules with `gap-2`.
            let lw = ceil(label.textWidth), dw = detailInline.isHidden ? 0 : ceil(detailInline.textWidth) + 4
            let pill = min(320, 8 + 12 + 6 + lw + dw + 8)
            let x = (bounds.width - pill) / 2
            leftRule.frame = NSRect(x: 0, y: 20, width: max(0, x - 8), height: 1)
            rightRule.frame = NSRect(x: x + pill + 8, y: 20, width: max(0, bounds.width - x - pill - 8), height: 1)
            icon.frame = NSRect(x: x + 8, y: 14, width: 12, height: 12)
            label.frame = NSRect(x: x + 26, y: 12, width: min(lw, pill - 34), height: 16)
            detailInline.frame = NSRect(x: label.frame.maxX + 4, y: 12, width: max(0, x + pill - 8 - label.frame.maxX - 4), height: 16)
        } else {
            let dh = detailHeight(bounds.width)
            card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1 + 8 + 16 + dh + 8 + 1)
            icon.frame = NSRect(x: 13, y: 11, width: 14, height: 14)
            label.frame = NSRect(x: 35, y: 9, width: bounds.width - 35 - 13, height: 16)
            detail.frame = NSRect(x: 35, y: 9 + 16 + 4, width: max(0, bounds.width - 35 - 13), height: max(0, dh - 4))
        }
    }
}
