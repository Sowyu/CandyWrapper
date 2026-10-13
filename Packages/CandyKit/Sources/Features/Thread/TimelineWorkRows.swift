import AppKit
import DesignSystem
import T3Protocol
import T3Store

// MARK: - Icons and details

@MainActor
enum WorkIcons {
    /// Muted icons: `iconMuted` at 70% opacity, and `brightness-60` in light mode (MessagesTimeline.tsx:4978).
    static var muted: NSColor {
        let base = TL.c(\.iconMuted)
        return NSColor(name: nil) { appearance in
            var out = base
            appearance.performAsCurrentDrawingAppearance {
                let c = base.usingColorSpace(.displayP3) ?? base
                out = appearance.isDark ? c.withAlphaComponent(0.7)
                    : NSColor(displayP3Red: c.redComponent * 0.6, green: c.greenComponent * 0.6, blue: c.blueComponent * 0.6, alpha: 0.7)
            }
            return out
        }
    }

    /// `toolGroupSummaryIconName` (MessagesTimeline.tsx:4051-4092).
    static func summary(_ kind: ToolGroupSummaryKind) -> IconName {
        switch kind {
        case "pull-request", "link-pr", "unlink-pr", "list-prs", "watch-pr", "unwatch-pr": .gitPullRequestArrow
        case "read": .eye
        case "edit": .squarePen
        case "command": .terminal
        case "thread-create": .brandT3Wordmark
        case "browser": .brandBrowserApp
        case "device": .smartphone
        case "search": .globe
        case "code-search": .search
        case "other": .wrench
        case "reasoning": .brain
        case "agent-tool": .bot
        case "tone-tool": .zap
        default: .hammer // dynamic-tool, update, mixed
        }
    }

    /// A T3 tool's `icon` (t3McpToolPresentation.ts): the wordmark, the browser app glyph, a phone or a pull request.
    static func tool(_ icon: String?) -> IconName? {
        switch icon {
        case "t3-code": .brandT3Wordmark
        case "browser": .brandBrowserApp
        case "device": .smartphone
        case "pull-request": .gitPullRequestArrow
        default: nil
        }
    }

    /// `workEntryIconName` (MessagesTimeline.tsx:5267-5303), first match wins.
    // ponytail: favicons and themed app logos (`ToolActivityIcon`) fall back to lucide glyphs; port them with provider tool sources
    static func entry(_ e: WorkLogEntry) -> IconName {
        if e.itemType == .notification {
            let raw = e.projectedItem?.item
            if raw?.string("outcome") == "failed" { return .circleAlert }
            switch NotificationSource.kind(raw?["source"]) {
            case "subagent", "delegated_task": return .bot
            case "command": return .terminal
            case "monitor": return .eye
            case "background_task": return .zap
            case "system": return .brandT3Wordmark // MessagesTimeline.tsx:5325-5326 in 2994
            default: break
            }
        }
        if e.itemType == .userInputRequest || e.itemType == .approvalRequest { return .messageCircle }
        if let icon = tool(WorkLog.toolPresentation(e)?.icon) { return icon }
        let action = WorkLog.toolGroupAction(e)
        if action != .other { return summary(action.rawValue) }
        if e.itemType == .dynamicTool { return .wrench }
        if e.itemType == .subagent { return .bot }
        switch e.tone {
        case .error: return .circleAlert
        case .thinking: return .brain
        case .info: return .check
        default: return .zap
        }
    }
}

// MARK: - One work log line

/// `WorkLogRow` + `WorkLogLine` (WorkLog.tsx:52-100): a 24px line with a 24px icon cell, `gap-1.5`,
/// a truncated label, the hover timestamp and a chevron cell that is reserved even when empty.
final class WorkLineView: DSView {
    enum Style { case tool, plain, destructive, warning }

    private var iconView = IconView(name: .zap, size: 16)
    private var iconName: IconName = .zap
    let label = ShineLabelView()
    private let time = LabelView("", font: TL.tabular(12), color: TL.c(\.mutedForeground))
    private let chevron = IconView(name: .chevronRight, size: 12)
    private var expanded = false
    /// "Open chat" after a created thread's label (MessagesTimeline.tsx:5674-5687, `text-sm text-primary`).
    private var trailingAction: ThreadStatusLineAction?
    /// A `t3_thread_read` row names its thread: the label holds `Read thread “`, then the linked title
    /// (`text-foreground`, underlined on hover) and the closing quote (ThreadReadLabel, :3930-3958).
    private var threadLink: ThreadStatusLineAction?
    private let threadLinkClose = LabelView("\u{201D}", font: TL.font(14), color: TL.c(\.secondaryLabel))

    var showsTime = false { didSet { if showsTime != oldValue { time.alphaValue = showsTime ? 1 : 0; needsLayout = true } } }
    /// The chevron cell is `invisible` (still 16px) when there is nothing to expand.
    var expandable = false { didSet { chevron.isHidden = !expandable } }
    /// The trailing slot holds only the timestamp, flush right, with no chevron cell (a failed error's row,
    /// MessagesTimeline.tsx:5444-5450).
    var timeOnlyTrailing = false { didSet { if timeOnlyTrailing != oldValue { needsLayout = true } } }

    /// `transition-transform duration-200`, `rotate-90` when open (MessagesTimeline.tsx:5713-5716).
    private func updateChevron(animated: Bool) {
        chevron.isHidden = !expandable
        chevron.setRotation(expanded ? 90 : 0, motion: animated ? .ease(0.2) : .none)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(label)
        time.lineHeight = 16
        time.alphaValue = 0
        addSubview(time)
        chevron.strokeColor = WorkIcons.muted
        addSubview(chevron)
    }

    /// The row takes clicks (it toggles the entry), except on the line's own buttons.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for control in [trailingAction, threadLink] {
            if let control, !control.isHidden, control.frame.contains(local) { return control }
        }
        return nil
    }

    func setTrailingAction(_ title: String?, _ action: (@MainActor () -> Void)?) {
        if title != nil, trailingAction == nil {
            let a = ThreadStatusLineAction()
            a.label.font = TL.font(14)
            a.label.lineHeight = 24
            a.tone = .primary
            addSubview(a)
            trailingAction = a
        }
        trailingAction?.isHidden = title == nil
        trailingAction?.label.text = title ?? ""
        trailingAction?.setAccessibilityLabel(title)
        trailingAction?.action = action
        needsLayout = true
    }

    /// Shows `prefix “title”` with the title opening its thread; nil restores the plain label.
    func setThreadLink(prefix: String?, title: String?, _ action: (@MainActor () -> Void)?) {
        if let prefix, let title {
            if threadLink == nil {
                let l = ThreadStatusLineAction()
                l.label.font = TL.font(14)
                l.label.lineHeight = 24
                l.tone = .foreground
                threadLinkClose.lineHeight = 24
                addSubview(l)
                addSubview(threadLinkClose)
                threadLink = l
            }
            label.text = prefix + " \u{201C}"
            threadLink?.label.text = title
            threadLink?.setAccessibilityLabel(title)
            threadLink?.action = action
        }
        threadLink?.isHidden = prefix == nil || title == nil
        threadLinkClose.isHidden = threadLink?.isHidden ?? true
        needsLayout = true
    }

    func configure(icon: IconName, text: String, style: Style, failed: Bool = false, time timestamp: T3Timestamp?, expanded: Bool, active: Bool = false, now: Date, animated: Bool = false) {
        if icon != iconName {
            iconView.removeFromSuperview()
            iconView = IconView(name: icon, size: 16)
            iconName = icon
            addSubview(iconView)
        }
        switch style {
        case .destructive:
            iconView.strokeColor = TL.c(\.destructive)
            label.base.color = TL.c(\.destructive)
            label.base.font = TL.font(14, .medium)
        case .warning:
            iconView.strokeColor = TL.c(\.warning)
            label.base.color = TL.c(\.warning)
            label.base.font = TL.font(14, .medium)
        case .tool, .plain:
            iconView.strokeColor = failed ? TL.c(\.toolErrorIcon, 0.4) : WorkIcons.muted
            label.base.color = style == .tool ? TL.c(\.secondaryLabel) : TL.c(\.foreground, 0.8)
            label.base.font = TL.font(14)
        }
        label.text = text
        label.shining = active
        time.text = TL.dayAwareTimestamp(timestamp, now: now)
        self.expanded = expanded
        updateChevron(animated: animated)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 24
        iconView.frame = NSRect(x: 4, y: 4, width: 16, height: 16)
        // Trailing slot, right to left: chevron cell (16), timestamp.
        let chevronX = timeOnlyTrailing ? bounds.width + 3 : bounds.width - 16
        chevron.frame = NSRect(x: chevronX + 2, y: 6, width: 12, height: 12)
        let timeWidth = showsTime ? ceil(time.textWidth) : 0
        time.frame = NSRect(x: chevronX - 6 - timeWidth, y: 4, width: timeWidth, height: 16)
        var right = showsTime ? time.frame.minX - 6 : chevronX - 6
        if let a = trailingAction, !a.isHidden {
            let w = a.preferredWidth
            a.frame = NSRect(x: right - w, y: 0, width: w, height: h)
            right = a.frame.minX - 6
        }
        label.frame = NSRect(x: 30, y: 0, width: max(0, min(ceil(label.textWidth) + 1, right - 30)), height: h)
        if let link = threadLink, !link.isHidden {
            // The three runs sit flush, as inline text does.
            let closeWidth = ceil(threadLinkClose.textWidth) + 1
            let x = min(label.frame.maxX, 30 + label.textWidth)
            link.frame = NSRect(x: x, y: 0, width: max(0, min(link.preferredWidth, right - closeWidth - x)), height: h)
            threadLinkClose.frame = NSRect(x: min(link.frame.maxX, x + link.label.textWidth), y: 0, width: closeWidth, height: h)
        }
    }
}

// MARK: - Rows

/// Shared by the work rows: the `WorkLogBlock` bottom padding. Each work line is its own
/// `group/timeline-row` (WorkLog.tsx:78), so hover reveals one line's timestamp, at once with no
/// fade (`TimelineRowTimestamp`, MessagesTimeline.tsx:2658-2695). Live and thinking rows have none.
class WorkRowBase: TimelineRowView {
    var lines: [WorkLineView] = []

    /// `pb-2` standalone, nothing when another work row follows.
    var blockPadding: CGFloat { item?.row.continuesWorkLog == true ? 0 : 8 }

    func line(_ i: Int) -> WorkLineView {
        while lines.count <= i {
            let l = WorkLineView()
            addSubview(l)
            lines.append(l)
        }
        lines[i].isHidden = false
        return lines[i]
    }

    func hideLines(from i: Int) { for l in lines.dropFirst(i) { l.isHidden = true } }

}

/// A `work` row: one tool call (`py-0.5`), or the open body of a group (`py-0` lines, `pb-1`).
final class WorkRowView: WorkRowBase {
    private var details: [WorkDetailView] = []
    private var entries: [(entry: WorkLogEntry, detail: WorkDetail, open: Bool)] = []
    private var isGroupBody = false
    /// Subagent notification cards by entry index (`SimpleWorkEntryRow`); nil draws the work line.
    private var cards: [SubagentCardLinkView?] = []
    /// An open thought's markdown by entry index (`ReasoningTraceContent`, MessagesTimeline.tsx:5739).
    private var traces: [ReasoningTraceView?] = []
    /// A group body of only thoughts draws them as one trace and no lines (MessagesTimeline.tsx:3447-3449).
    private var groupTrace: ReasoningTraceView?
    private(set) var traceOnly = false

    private func trace(_ i: Int) -> ReasoningTraceView {
        while traces.count <= i { traces.append(nil) }
        if let t = traces[i] { t.isHidden = false; return t }
        let t = ReasoningTraceView()
        addSubview(t)
        traces[i] = t
        return t
    }

    private func hasTrace(_ i: Int) -> Bool { i < traces.count && traces[i]?.isHidden == false }

    /// A failed error's message and Retry, by entry index (MessagesTimeline.tsx:5419-5469).
    private var failures: [WorkFailureView?] = []

    private func failure(_ i: Int) -> WorkFailureView? { i < failures.count && failures[i]?.isHidden == false ? failures[i] : nil }

    /// A failed error item takes T3's error branch: no inspector, the message below, a usage limit without it.
    private static func failedError(_ e: WorkLogEntry) -> (message: String?, runId: RunId?)? {
        guard let item = e.projectedItem?.item, item.type == .error, item.status == .failed else { return nil }
        let warning = item["failure"]?["class"]?.stringValue == "usage_limit"
        return (warning ? nil : item["failure"]?["message"]?.stringValue ?? "", item.runId)
    }

    /// A failed error's heading is its own label ("Provider error"), not the display label, which is the message
    /// shown below it; a usage limit reads "Usage limit reached." with the reset time (MessagesTimeline.tsx:5414-5420).
    static func failedErrorLabel(_ e: WorkLogEntry) -> String? {
        guard let item = e.projectedItem?.item, item.type == .error, item.status == .failed else { return nil }
        guard item["failure"]?["class"]?.stringValue == "usage_limit" else { return e.label }
        let reset = item["failure"]?["resetAt"]?.stringValue
            .map { UsageTime.upcoming($0, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) }.flatMap { $0.isEmpty ? nil : $0 }
        return "Usage limit reached." + (reset.map { " Retry after \($0)." } ?? "")
    }

    /// The row opens: an inspector to show, or a thought with text (`canExpandProjectedItem`, :5552-5561).
    private func expandable(_ i: Int) -> Bool {
        let e = entries[i].entry
        if Self.failedError(e) != nil { return false }
        return !entries[i].detail.isEmpty || (e.itemType == .reasoning && !(e.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    override func configure(_ item: TimelineItem) {
        // The same row reconfigured in place: an entry's chevron turns instead of snapping.
        let sameRow = self.item?.id == item.id
        super.configure(item)
        guard case .work(let grouped, let isGroup, let displayLabel) = item.row.kind else { return }
        isGroupBody = isGroup
        let root = context.workspaceRoot
        entries = grouped.map { e in
            let label = (!isGroup ? displayLabel : nil) ?? WorkLog.displayLabel(e, workspaceRoot: root)
            return (e, WorkDetail.of(e, label: label, workspaceRoot: root, output: item.ui.outputs[e.id],
                                     checkpointStatus: { [weak model = context.model] id in model?.checkpointStatus(id) }),
                    item.ui.expandedEntries.contains(e.id))
        }
        while cards.count < entries.count { cards.append(nil) }
        traceOnly = isGroup && !grouped.isEmpty && grouped.allSatisfy { $0.itemType == .reasoning }
        if traceOnly {
            let t = groupTrace ?? ReasoningTraceView()
            if groupTrace == nil { groupTrace = t; addSubview(t) }
            t.isHidden = false
            t.set(grouped.map(ReasoningTraceView.Item.init), context: context)
            hideLines(from: 0)
            details.forEach { $0.isHidden = true }
            failures.forEach { $0?.isHidden = true }
            cards.forEach { $0?.stop(); $0?.isHidden = true }
            traces.forEach { $0?.isHidden = true }
            needsLayout = true
            return
        }
        groupTrace?.isHidden = true
        for (i, (e, detail, open)) in entries.enumerated() {
            if let card = SubagentCardPresentation.notificationCard(e, records: item.ui.subagentRecords) {
                let view = cards[i] ?? SubagentCardLinkView()
                if cards[i] == nil { cards[i] = view; addSubview(view) }
                view.isHidden = false
                view.configure(card)
                view.action = { [weak self] in
                    guard let child = card.child else { return }
                    self?.context.model?.onOpenThread?(child)
                }
                line(i).isHidden = true
                entries[i].detail = WorkDetail()
                entries[i].open = false
                if details.count > i { details[i].isHidden = true }
                if failures.count > i { failures[i]?.isHidden = true }
                continue
            }
            if let card = cards[i] { card.stop(); card.isHidden = true }
            let thought = e.itemType == .reasoning
            // An open thought's heading steps back to Thinking or Thought; the trace below holds the text (:5491-5496).
            let label = thought && open ? (e.toolLifecycleStatus == .inProgress ? "Thinking" : "Thought")
                : Self.failedErrorLabel(e) ?? (!isGroup ? displayLabel : nil) ?? WorkLog.displayLabel(e, workspaceRoot: root)
            let failed = WorkLog.displayIndicatesFailure(e)
            let toolLike = WorkLog.isToolLike(e)
            let severe = failed && (e.itemType == .error || !toolLike)
            let warning = e.sourceActivityKind == "runtime.warning"
            let style: WorkLineView.Style = warning ? .warning : severe ? .destructive : toolLike ? .tool : .plain
            let icon: IconName = warning || severe ? .circleAlert : WorkIcons.entry(e)
            let l = line(i)
            l.configure(icon: icon, text: label, style: style, failed: failed, time: e.createdAt, expanded: open, now: context.now(), animated: sameRow)
            l.expandable = expandable(i)
            l.timeOnlyTrailing = Self.failedError(e) != nil
            let model = context.model
            let created = e.projectedItem?.item.type == .threadCreated ? e.projectedItem?.string("targetThreadId").map { ThreadId($0) } : nil
            l.setTrailingAction(created == nil ? nil : "Open chat", created.map { id in { model?.onOpenThread?(id) } })
            let readTarget = WorkLog.threadReadTargetId(e).map { ThreadId($0) }
            let readTitle = readTarget.flatMap { model?.threadTitle?($0) }
            l.setThreadLink(prefix: readTitle == nil ? nil : WorkLog.threadReadLabelPrefix(label), title: readTitle,
                            readTarget.map { id in { model?.onOpenThread?(id) } })
            if pinnedTime.count <= i { pinnedTime.append(false) }
            pinnedTime[i] = severe
            l.showsTime = hoveredEntry == i || severe
            while details.count <= i {
                let d = WorkDetailView()
                addSubview(d)
                details.append(d)
            }
            details[i].detail = detail
            details[i].onAction = { [weak self] action in self?.context.model?.perform(action) }
            let failedError = Self.failedError(e)
            details[i].isHidden = !open || detail.blocks.isEmpty || thought || failedError != nil
            while failures.count <= i { failures.append(nil) }
            let retry = failedError?.runId.flatMap { item.ui.retryRunIds.contains($0) ? $0 : nil }
            if let failedError, failedError.message != nil || retry != nil {
                let view = failures[i] ?? WorkFailureView()
                if failures[i] == nil { failures[i] = view; addSubview(view) }
                view.isHidden = false
                view.message = failedError.message
                if let retry {
                    view.onRetry = { [weak self] in self?.context.model?.onRetryWorkspacePreparation?(retry) }
                } else {
                    view.onRetry = nil
                }
            } else {
                failures[i]?.isHidden = true
            }
            if thought, open, expandable(i) {
                trace(i).set([ReasoningTraceView.Item(e)], context: context)
            } else if i < traces.count {
                traces[i]?.isHidden = true
            }
        }
        for t in traces.dropFirst(entries.count) { t?.isHidden = true }
        hideLines(from: entries.count)
        for d in details.dropFirst(entries.count) { d.isHidden = true }
        for f in failures.dropFirst(entries.count) { f?.isHidden = true }
        for c in cards.dropFirst(entries.count) { c?.stop(); c?.isHidden = true }
        needsLayout = true
    }

    override func setContentVisible(_ visible: Bool) {
        super.setContentVisible(visible)
        cards.forEach { $0?.contentVisible = visible }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cards.forEach { $0?.stop() }
    }

    private func isCard(_ i: Int) -> Bool { i < cards.count && cards[i]?.isHidden == false }

    /// Failed error rows keep their timestamp visible.
    private var pinnedTime: [Bool] = []

    /// Each entry's span: its line, its open detail and the `py-0.5` around them (WorkLogRow wraps both).
    private var spans: [ClosedRange<CGFloat>] = []
    private var hoveredEntry: Int?
    override var tracksPointerMoves: Bool { true }

    override func hoverChanged() {
        let y = pointer?.y
        let entry = y.flatMap { y in spans.prefix(entries.count).firstIndex { $0.contains(y) } }
        guard entry != hoveredEntry else { return }
        hoveredEntry = entry
        for (i, l) in lines.enumerated() { l.showsTime = i == entry || (i < pinnedTime.count && pinnedTime[i]) }
    }

    private var rowPad: CGFloat { isGroupBody ? 0 : 2 }

    /// Detail box `mt-0.5 mb-1.5`, indented like `ms-7` for text (28px) and flush for panels.
    private func detailHeight(_ i: Int, _ width: CGFloat) -> CGFloat {
        if hasTrace(i), let t = traces[i] { return t.height(forWidth: ReasoningTraceView.width(in: width)) }
        guard entries[i].open, !entries[i].detail.blocks.isEmpty else { return 0 }
        return 2 + details[i].height(forWidth: max(0, width - 4)) + 6
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        if traceOnly, let t = groupTrace { return t.height(forWidth: ReasoningTraceView.width(in: width)) + 4 }
        var h: CGFloat = 0
        for i in entries.indices {
            h += isCard(i) ? SubagentCardLinkView.height
                : rowPad * 2 + 24 + (failure(i)?.height(forWidth: width - 4) ?? 0) + detailHeight(i, width)
        }
        return h + (isGroupBody ? 4 : blockPadding)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        spans.removeAll(keepingCapacity: true)
        if traceOnly, let t = groupTrace {
            let w = ReasoningTraceView.width(in: bounds.width)
            t.frame = NSRect(x: ReasoningTraceView.inset, y: 0, width: w, height: t.height(forWidth: w))
            return
        }
        for i in entries.indices {
            let start = y
            defer { spans.append(start...max(start, y - 0.001)) }
            if isCard(i), let card = cards[i] {
                card.frame = NSRect(x: 0, y: y, width: bounds.width, height: SubagentCardLinkView.height)
                y += SubagentCardLinkView.height
                continue
            }
            y += rowPad
            lines[i].frame = NSRect(x: 2, y: y, width: bounds.width - 4, height: 24)
            y += 24
            if let f = failure(i) {
                let fh = f.height(forWidth: bounds.width - 4)
                f.frame = NSRect(x: 2, y: y, width: bounds.width - 4, height: fh)
                y += fh
            }
            let dh = detailHeight(i, bounds.width)
            if hasTrace(i), let t = traces[i] {
                t.frame = NSRect(x: ReasoningTraceView.inset, y: y, width: ReasoningTraceView.width(in: bounds.width), height: dh)
            } else if dh > 0 { details[i].frame = NSRect(x: 2, y: y + 2, width: bounds.width - 4, height: dh - 8) }
            y += dh + rowPad
        }
        // An entry that opened or closed under a still pointer moves the spans.
        if hovered { hoverChanged() }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !traceOnly, let i = lines.prefix(entries.count).firstIndex(where: { !$0.isHidden && $0.frame.contains(p) }), expandable(i) else {
            return super.mouseUp(with: event)
        }
        context.disclosure(item?.id)
        context.model?.toggleEntry(entries[i].entry.id)
    }

    override func mouseDown(with event: NSEvent) {}
}

/// Below a failed error's line (MessagesTimeline.tsx:5451-5468): the failure message `ms-7 py-1 text-sm
/// leading-relaxed text-foreground/80`, then for a failed workspace preparation an outline xs Retry `ms-7 pb-1`.
final class WorkFailureView: DSView {
    private let text = TextBlockView("", font: TL.font(14), lineHeight: 22.75, color: TL.c(\.foreground, 0.8))
    private let retry = ButtonView("Retry", icon: .rotateCcw, variant: .outline, size: .xs)
    private static let inset: CGFloat = 28

    var message: String? { didSet { text.text = message ?? ""; text.isHidden = message == nil; needsLayout = true } }
    var onRetry: (@MainActor () -> Void)? {
        didSet { retry.isHidden = onRetry == nil; retry.action = { [weak self] in self?.onRetry?() }; needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(text)
        addSubview(retry)
        retry.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func textHeight(_ width: CGFloat) -> CGFloat {
        guard let message else { return 0 }
        return 4 + (message.isEmpty ? 0 : text.height(forWidth: max(0, width - Self.inset))) + 4
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        textHeight(width) + (onRetry == nil ? 0 : 24 + 4)
    }

    override func layout() {
        super.layout()
        let th = textHeight(bounds.width)
        text.frame = NSRect(x: Self.inset, y: 4, width: max(0, bounds.width - Self.inset), height: max(0, th - 8))
        retry.frame = NSRect(x: Self.inset, y: th, width: retry.intrinsicContentSize.width, height: 24)
    }
}

/// `ReasoningTraceContent` (MessagesTimeline.tsx:5328-5352) in `WorkLogDetails` (WorkLog.tsx:126-133): each
/// thought as foreground markdown with line breaks kept, `gap-3` apart, in a box `ms-7 px-0.5 py-1` that
/// scrolls past `max-h-96`.
final class ReasoningTraceView: DSView {
    struct Item {
        var key: String
        var text: String
        var streaming: Bool
        init(_ e: WorkLogEntry) {
            key = "trace:" + e.id
            text = e.detail ?? ""
            streaming = e.toolLifecycleStatus == .inProgress
        }
    }

    /// `ms-7` from the row's edge (the lines sit 2pt in).
    static let inset: CGFloat = 2 + 28
    static func width(in rowWidth: CGFloat) -> CGFloat { max(0, rowWidth - inset - 2) }

    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollbars: .native) // `max-h-96 overflow-auto` (WorkLog.tsx:130)
    private var views: [MarkdownView] = []
    private var count = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(scroll)
    }

    func set(_ items: [Item], context: TimelineContext) {
        while views.count < items.count {
            let m = MarkdownView(frame: .zero)
            m.bodyColor = TL.c(\.foreground)
            document.addSubview(m)
            views.append(m)
        }
        count = items.count
        for (i, v) in views.enumerated() { v.isHidden = i >= count }
        for (v, item) in zip(views, items) {
            v.cwd = context.markdownCwd
            v.onOpenFile = context.model?.openFile
            v.document = context.document(item.key, item.text, lineBreaks: true, streaming: item.streaming)
        }
        needsLayout = true
    }

    private func contentHeight(_ width: CGFloat) -> CGFloat {
        let inner = max(0, width - 4)
        return 8 + views.prefix(count).reduce(0) { $0 + $1.height(forWidth: inner) } + 12 * CGFloat(max(0, count - 1))
    }

    func height(forWidth width: CGFloat) -> CGFloat { min(384, contentHeight(width)) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let inner = max(0, bounds.width - 4)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight(bounds.width))
        var y: CGFloat = 4
        for v in views.prefix(count) {
            let h = v.height(forWidth: inner)
            v.frame = NSRect(x: 2, y: y, width: inner, height: h)
            y += h + 12
        }
    }
}

/// `work-toggle`: the header of a settled group (`WorkGroupHeader`, :4114-4151). The whole row toggles it.
final class WorkToggleRowView: WorkRowBase {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        onClick = { [weak self] in
            guard let self, case .workToggle(let t)? = self.item?.row.kind else { return }
            self.context.disclosure(self.item?.id)
            self.context.model?.toggleGroup(t.groupId)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .workToggle(let t) = item.row.kind else { return }
        let icon = WorkIcons.tool(t.summaryToolIcon) ?? WorkIcons.summary(t.summaryKind)
        let l = line(0)
        l.configure(icon: icon, text: t.summary, style: .tool, failed: t.hasFailure, time: item.row.createdAt, expanded: false, now: context.now())
        l.expandable = false
        l.showsTime = hovered
        setAccessibilityRole(.button)
        setAccessibilityExpanded(t.expanded)
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 28 + blockPadding }

    override func hoverChanged() { line(0).showsTime = hovered }

    override func layout() {
        super.layout()
        line(0).frame = NSRect(x: 2, y: 2, width: bounds.width - 4, height: 24)
    }
}

/// `work-live`: the running turn's activity line (LiveWorkEntryTimelineRow, :3960-4049), with the
/// latest thought above it (up to 4 lines) and the shine on the label while a tool runs.
final class WorkLiveRowView: WorkRowBase {
    private let thoughtIcon = IconView(name: .brain, size: 16, strokeColor: WorkIcons.muted)
    private let thought = TextBlockView("", font: TL.font(14), lineHeight: TL.relaxed, color: TL.c(\.secondaryLabel))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thought.maxLines = 4
        addSubview(thoughtIcon)
        addSubview(thought)
        onClick = { [weak self] in
            guard let self, case .workLive(_, _, let groupId, _, _, _)? = self.item?.row.kind else { return }
            self.context.disclosure(self.item?.id)
            self.context.model?.toggleGroup(groupId)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .workLive(let entry, _, _, let expanded, let active, let thoughtEntry) = item.row.kind else { return }
        // The expanded group already lists the thought, so the preview steps aside (MessagesTimeline.tsx:3970-3971).
        let preview = expanded ? "" : (thoughtEntry?.detail.map(liveThoughtLine) ?? "")
        thought.text = preview
        thought.isHidden = preview.isEmpty
        thoughtIcon.isHidden = preview.isEmpty
        // While the thought itself is the latest entry, the status line says Thinking instead of repeating it (:3972-3973).
        let thoughtIsStatus = !preview.isEmpty && thoughtEntry?.id == entry.id
        let label = thoughtIsStatus ? (active ? "Thinking" : "Thought") : WorkLog.liveLabel(entry, workspaceRoot: context.workspaceRoot, active: active)
        let l = line(0)
        l.configure(icon: WorkIcons.entry(entry), text: label,
                    style: .tool, time: entry.createdAt, expanded: false, active: active, now: context.now())
        l.expandable = false
        needsLayout = true
    }

    private func thoughtHeight(_ width: CGFloat) -> CGFloat {
        thought.isHidden ? 0 : 2 + max(24, thought.height(forWidth: max(0, width - 34))) + 2
    }

    override func height(forWidth width: CGFloat) -> CGFloat { thoughtHeight(width) + 28 + blockPadding }

    override func layout() {
        super.layout()
        let th = thoughtHeight(bounds.width)
        thoughtIcon.frame = NSRect(x: 6, y: 2 + (TL.relaxed - 16) / 2, width: 16, height: 16)
        thought.frame = NSRect(x: 32, y: 2, width: max(0, bounds.width - 34), height: max(0, th - 4))
        line(0).frame = NSRect(x: 2, y: th + 2, width: bounds.width - 4, height: 24)
    }
}

/// `thinking`: "Thinking" with the brain icon and the shine, while the run has no visible activity.
final class ThinkingRowView: WorkRowBase {
    private var blank = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        onClick = { [weak self] in
            guard let self, case .thinking(let groupId?, _, _)? = self.item?.row.kind else { return }
            self.context.disclosure(self.item?.id)
            self.context.model?.toggleGroup(groupId)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        let l = line(0)
        // While a `/compact` waits for its row, the slot stays at its height with nothing in it (:3793-3795).
        if case .thinking(_, _, let compacting) = item.row.kind { blank = compacting } else { blank = false }
        l.isHidden = blank
        l.configure(icon: .brain, text: "Thinking", style: .tool, time: nil, expanded: false, active: !blank, now: context.now())
        l.label.style = .focus // `LiveActivityRow ... shimmer` (MessagesTimeline.tsx:3796)
        l.expandable = false
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 28 + blockPadding }

    override func layout() {
        super.layout()
        // `line(0)` shows the line it hands out, so the blank state goes back on after.
        let l = line(0)
        l.frame = NSRect(x: 2, y: 2, width: bounds.width - 4, height: 24)
        l.isHidden = blank
    }
}

/// `WorkingTimelineRow` (:3705-3743): "Working for 4s" over a hairline. The seconds tick on the
/// shared `LabelClock`, only while the row is on screen in a visible window. While a `/compact`
/// waits for its compaction row it reads "Compacting…" after the minimize icon, with the shimmer
/// (`CompactingLabel`, :3782-3789), and nothing ticks.
final class WorkingRowView: TimelineRowView {
    private let label = LabelView("", font: TL.tabular(14), color: TL.c(\.mutedForeground))
    private let compactingIcon = IconView(name: .minimize2, size: 12, strokeColor: TL.c(\.mutedForeground))
    private let compactingLabel = ShineLabelView()
    private let rule = FillView()
    private var startMs: Int64?
    private var compacting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = TL.relaxed
        addSubview(label)
        compactingLabel.base.font = TL.tabular(14)
        compactingLabel.base.lineHeight = TL.relaxed
        compactingLabel.base.color = TL.c(\.mutedForeground)
        compactingLabel.style = .focus
        compactingLabel.text = "Compacting…"
        addSubview(compactingIcon)
        addSubview(compactingLabel)
        rule.fill = TL.c(\.border, 0.6)
        addSubview(rule)
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        startMs = item.row.createdAt?.epochMs
        if case .working(let c) = item.row.kind { compacting = c } else { compacting = false }
        label.isHidden = compacting
        compactingIcon.isHidden = !compacting
        compactingLabel.isHidden = !compacting
        compactingLabel.shining = compacting
        needsLayout = true
        tick()
    }

    /// `formatWorkingTimer` (:3477-3490). The text shows whole seconds, so it changes once a second.
    private func tick() {
        if compacting { LabelClock.shared.cancel(self); return }
        guard let startMs else { label.text = "Working..."; LabelClock.shared.cancel(self); return }
        let elapsedMs = max(0, Int64(context.now().timeIntervalSince1970 * 1000) - startMs)
        let seconds = elapsedMs / 1000
        label.text = "Working for " + (seconds < 60 ? "\(seconds)s" : formatDuration(Double(seconds) * 1000))
        LabelClock.shared.schedule(self, in: Double(1000 - elapsedMs % 1000) / 1000) { [weak self] in self?.tick() }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); LabelClock.shared.visibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); LabelClock.shared.visibilityChanged() }

    override func height(forWidth width: CGFloat) -> CGFloat { 4 + 24 + 8 + 1 + 6 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 4, y: 4 + (24 - TL.relaxed) / 2, width: bounds.width - 8, height: TL.relaxed)
        if compacting {
            // `inline-flex items-center gap-1.5`: the 12pt icon centered on the line, then the text.
            compactingIcon.frame = NSRect(x: 4, y: 10, width: 12, height: 12)
            compactingLabel.frame = NSRect(x: 4 + 12 + 6, y: label.frame.minY, width: ceil(compactingLabel.textWidth), height: TL.relaxed)
        }
        rule.frame = NSRect(x: 0, y: 36, width: bounds.width, height: 1)
    }
}
