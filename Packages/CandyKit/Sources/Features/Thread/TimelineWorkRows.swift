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
        case "thread-create": .messageSquare
        case "browser": .globe2
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

    /// `workEntryIconName` (MessagesTimeline.tsx:5267-5303), first match wins.
    // ponytail: T3 MCP tool icons, favicons and app icons fall back to lucide glyphs; add the image icons with MCP tools
    static func entry(_ e: WorkLogEntry) -> IconName {
        if e.itemType == .notification {
            let raw = e.projectedItem?.item
            if raw?.string("outcome") == "failed" { return .circleAlert }
            switch raw?["source"]?["kind"]?.stringValue {
            case "subagent", "delegated_task": return .bot
            case "command": return .terminal
            case "monitor": return .eye
            case "background_task": return .zap
            default: break
            }
        }
        if e.itemType == .userInputRequest || e.itemType == .approvalRequest { return .messageCircle }
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

/// What an expanded entry shows: blocks of mono text (the `V2ItemInspector` essentials).
struct WorkDetail: Hashable {
    /// `note` is the muted italic of "Loading output…" and "No output.".
    enum Tone: Hashable { case command, output, error, note }
    var blocks: [(String, Tone)] = []
    /// The stream left this entry's output out; it loads when the row opens, so the row expands
    /// even before anything is fetched (`turnItemHasDetail`, itemDetail.ts:227-248).
    var fetches = false
    var isEmpty: Bool { blocks.isEmpty && !fetches }

    static func == (a: WorkDetail, b: WorkDetail) -> Bool { a.blocks.map(\.0) == b.blocks.map(\.0) && a.fetches == b.fetches }
    func hash(into h: inout Hasher) { h.combine(blocks.map(\.0)) }

    /// `V2ItemInspector.tsx:222-424` reduced to text: the command, the output, a failing exit code,
    /// read paths, changed files, or the entry's detail. `output` is the fetch state of an output
    /// the stream left out.
    // ponytail: no search result links, JSON highlighting or Open diff button; add with the inspector's rich blocks
    static func of(_ e: WorkLogEntry, label: String, workspaceRoot: String?, output: ToolOutputState? = nil) -> WorkDetail {
        var d = WorkDetail()
        d.fetches = e.projectedItem.map { TurnItemDetail.needsFetch($0.item) } ?? false
        func add(_ text: String?, _ tone: Tone) {
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != label,
                  !d.blocks.contains(where: { $0.0 == t }) else { return }
            d.blocks.append((t, tone))
        }
        /// `ToolOutput` (V2ItemInspector.tsx:149-175): the text, else loading, error or empty.
        func addFetched() {
            switch output {
            case .loading: d.blocks.append(("Loading output…", .note))
            case .failed(let message): d.blocks.append(("Couldn't load output: " + message, .error))
            case .fetched(.gone): d.blocks.append(("Couldn't load output: Output is no longer available.", .error))
            case .fetched(.output(let text?)) where !text.isEmpty: d.blocks.append((text, .output))
            case .fetched(.output): d.blocks.append(("No output.", .note))
            case .fetched(.mismatch), nil: break
            }
        }
        let item = e.structuredPayload
        if let read = WorkLog.readOutput(e, workspaceRoot: workspaceRoot), WorkLog.toolGroupAction(e) == .read {
            // A read expands to its plain text, then the output fetched for it (MessagesTimeline.tsx:5549-5553, :5764-5770).
            add(read, .output)
            if d.fetches { addFetched() }
            return d
        }
        if e.itemType == .commandExecution || e.command != nil {
            add((e.command ?? item?.input?.stringValue).map(commandDisplayText), .command)
            if d.fetches { addFetched() } else { add(item?.output?.stringValue ?? e.detail, .output) }
            if let code = item?.exitCode, code != 0 { d.blocks.append(("exit \(code)", .error)) }
            return d
        }
        if e.itemType == .fileChange, let files = e.changedFiles {
            add(files.map { formatWorkspaceRelativePath($0, workspaceRoot: workspaceRoot) }.joined(separator: "\n"), .output)
            return d
        }
        add(e.detail, .output)
        if d.fetches { addFetched() } else if let out = item?.output?.stringValue { add(out, .output) }
        return d
    }
}

/// Mono detail blocks, `space-y-1.5`, 13px at `leading-relaxed`, each clipped at 320px.
final class WorkDetailView: DSView {
    static let font = DSFont.mono(13)
    static let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    static let lineHeight: CGFloat = 13 * 1.625
    static let maxBlock: CGFloat = 320

    var detail = WorkDetail() { didSet { if detail != oldValue { cache = nil; needsDisplay = true } } }
    private var cache: (width: CGFloat, layouts: [TextBlockLayout])?

    override var wantsUpdateLayer: Bool { false }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.isOpaque = false
        clipsToBounds = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func layouts(_ width: CGFloat) -> [TextBlockLayout] {
        if let cache, cache.width == width { return cache.layouts }
        let made = detail.blocks.map { text, tone in
            let color: NSColor = switch tone {
            case .command: TL.c(\.foreground, 0.85)
            case .output, .note: TL.c(\.mutedForeground)
            case .error: TL.c(\.destructive)
            }
            let font = tone == .note ? Self.italic : Self.font
            return TextBlockLayout(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]),
                                   width: width, lineHeight: Self.lineHeight)
        }
        cache = (width, made)
        return made
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let ls = layouts(width)
        guard !ls.isEmpty else { return 0 }
        return ls.reduce(0) { $0 + min($1.height, Self.maxBlock) } + CGFloat(ls.count - 1) * 6
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldSmoothFonts(true)
        var y: CGFloat = 0
        for layout in layouts(bounds.width) {
            let h = min(layout.height, Self.maxBlock)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: y, width: bounds.width, height: h))
            // ponytail: long output is clipped at 320px instead of scrolling inside; add a nested scroller if people read long output here
            layout.draw(in: ctx, origin: CGPoint(x: 0, y: y), width: bounds.width, alignment: .left)
            ctx.restoreGState()
            y += h + 6
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
    private let chevronOpen = IconView(name: .chevronDown, size: 12)
    private var expanded = false

    var showsTime = false { didSet { if showsTime != oldValue { time.alphaValue = showsTime ? 1 : 0; needsLayout = true } } }
    /// The chevron cell is `invisible` (still 16px) when there is nothing to expand.
    var expandable = false { didSet { updateChevron() } }

    // ponytail: the chevron swaps instead of rotating over 200ms; rotate a container layer if it matters
    private func updateChevron() {
        chevron.isHidden = !expandable || expanded
        chevronOpen.isHidden = !expandable || !expanded
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(label)
        time.lineHeight = 16
        time.alphaValue = 0
        addSubview(time)
        for c in [chevron, chevronOpen] {
            c.strokeColor = WorkIcons.muted
            addSubview(c)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(icon: IconName, text: String, style: Style, failed: Bool = false, time timestamp: T3Timestamp?, expanded: Bool, active: Bool = false, now: Date) {
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
        updateChevron()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 24
        iconView.frame = NSRect(x: 4, y: 4, width: 16, height: 16)
        // Trailing slot, right to left: chevron cell (16), timestamp.
        let chevronX = bounds.width - 16
        chevron.frame = NSRect(x: chevronX + 2, y: 6, width: 12, height: 12)
        chevronOpen.frame = chevron.frame
        let timeWidth = showsTime ? ceil(time.textWidth) : 0
        time.frame = NSRect(x: chevronX - 6 - timeWidth, y: 4, width: timeWidth, height: 16)
        let right = showsTime ? time.frame.minX - 6 : chevronX - 6
        label.frame = NSRect(x: 30, y: 0, width: max(0, min(ceil(label.textWidth) + 1, right - 30)), height: h)
    }
}

// MARK: - Rows

/// Shared by the work rows: the `WorkLogBlock` bottom padding and the timestamp hover.
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

    override func hoverChanged() {
        lines.forEach { $0.showsTime = hovered }
        lines.forEach { $0.needsLayout = true }
    }
}

/// A `work` row: one tool call (`py-0.5`), or the open body of a group (`py-0` lines, `pb-1`).
final class WorkRowView: WorkRowBase {
    private var details: [WorkDetailView] = []
    private var entries: [(entry: WorkLogEntry, detail: WorkDetail, open: Bool)] = []
    private var isGroupBody = false

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .work(let grouped, let isGroup, let displayLabel) = item.row.kind else { return }
        isGroupBody = isGroup
        let root = context.workspaceRoot
        entries = grouped.map { e in
            let label = (!isGroup ? displayLabel : nil) ?? WorkLog.displayLabel(e, workspaceRoot: root)
            return (e, WorkDetail.of(e, label: label, workspaceRoot: root, output: item.ui.outputs[e.id]), item.ui.expandedEntries.contains(e.id))
        }
        for (i, (e, detail, open)) in entries.enumerated() {
            let label = (!isGroup ? displayLabel : nil) ?? WorkLog.displayLabel(e, workspaceRoot: root)
            let failed = WorkLog.displayIndicatesFailure(e)
            let toolLike = WorkLog.isToolLike(e)
            let severe = failed && (e.itemType == .error || !toolLike)
            let warning = e.sourceActivityKind == "runtime.warning"
            let style: WorkLineView.Style = warning ? .warning : severe ? .destructive : toolLike ? .tool : .plain
            let icon: IconName = warning || severe ? .circleAlert : WorkIcons.entry(e)
            let l = line(i)
            l.configure(icon: icon, text: label, style: style, failed: failed, time: e.createdAt, expanded: open, now: context.now())
            l.expandable = !detail.isEmpty
            if pinnedTime.count <= i { pinnedTime.append(false) }
            pinnedTime[i] = severe
            l.showsTime = hovered || severe
            while details.count <= i {
                let d = WorkDetailView()
                addSubview(d)
                details.append(d)
            }
            details[i].detail = detail
            details[i].isHidden = !open || detail.blocks.isEmpty
        }
        hideLines(from: entries.count)
        for d in details.dropFirst(entries.count) { d.isHidden = true }
        needsLayout = true
    }

    /// Failed error rows keep their timestamp visible.
    private var pinnedTime: [Bool] = []

    override func hoverChanged() {
        for (i, l) in lines.enumerated() { l.showsTime = hovered || (i < pinnedTime.count && pinnedTime[i]) }
        needsLayout = true
    }

    private var rowPad: CGFloat { isGroupBody ? 0 : 2 }

    /// Detail box `mt-0.5 mb-1.5`, indented like `ms-7` for text (28px) and flush for panels.
    private func detailHeight(_ i: Int, _ width: CGFloat) -> CGFloat {
        guard entries[i].open, !entries[i].detail.blocks.isEmpty else { return 0 }
        return 2 + details[i].height(forWidth: max(0, width - 4)) + 6
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        for i in entries.indices { h += rowPad * 2 + 24 + detailHeight(i, width) }
        return h + (isGroupBody ? 4 : blockPadding)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for i in entries.indices {
            y += rowPad
            lines[i].frame = NSRect(x: 2, y: y, width: bounds.width - 4, height: 24)
            y += 24
            let dh = detailHeight(i, bounds.width)
            if dh > 0 { details[i].frame = NSRect(x: 2, y: y + 2, width: bounds.width - 4, height: dh - 8) }
            y += dh + rowPad
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = lines.prefix(entries.count).firstIndex(where: { $0.frame.contains(p) }), !entries[i].detail.isEmpty else {
            return super.mouseUp(with: event)
        }
        context.model?.toggleEntry(entries[i].entry.id)
    }

    override func mouseDown(with event: NSEvent) {}
}

/// `work-toggle`: the header of a settled group (`WorkGroupHeader`, :4114-4151). The whole row toggles it.
final class WorkToggleRowView: WorkRowBase {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        onClick = { [weak self] in
            guard let self, case .workToggle(let t)? = self.item?.row.kind else { return }
            self.context.model?.toggleGroup(t.groupId)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .workToggle(let t) = item.row.kind else { return }
        let icon: IconName = t.summaryToolIcon == "device" ? .smartphone : t.summaryToolIcon == "pull-request" ? .gitPullRequestArrow
            : WorkIcons.summary(t.summaryKind)
        let l = line(0)
        l.configure(icon: icon, text: t.summary, style: .tool, failed: t.hasFailure, time: item.row.createdAt, expanded: false, now: context.now())
        l.expandable = false
        l.showsTime = hovered
        setAccessibilityRole(.button)
        setAccessibilityExpanded(t.expanded)
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 28 + blockPadding }

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
            self.context.model?.toggleGroup(groupId)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .workLive(let entry, _, _, _, let active, let thoughtEntry) = item.row.kind else { return }
        let preview = thoughtEntry?.detail.map(liveThoughtLine) ?? ""
        thought.text = preview
        thought.isHidden = preview.isEmpty
        thoughtIcon.isHidden = preview.isEmpty
        let l = line(0)
        l.configure(icon: WorkIcons.entry(entry), text: WorkLog.liveLabel(entry, workspaceRoot: context.workspaceRoot, active: active),
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
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        onClick = { [weak self] in
            guard let self, case .thinking(let groupId?, _)? = self.item?.row.kind else { return }
            self.context.model?.toggleGroup(groupId)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        let l = line(0)
        l.configure(icon: .brain, text: "Thinking", style: .tool, time: nil, expanded: false, active: true, now: context.now())
        l.expandable = false
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 28 + blockPadding }

    override func layout() {
        super.layout()
        line(0).frame = NSRect(x: 2, y: 2, width: bounds.width - 4, height: 24)
    }
}

/// `WorkingTimelineRow` (:3705-3743): "Working for 4s" over a hairline. The seconds tick once a
/// second only while the row is on screen in a visible window.
final class WorkingRowView: TimelineRowView {
    private let label = LabelView("", font: TL.tabular(14), color: TL.c(\.mutedForeground))
    private let rule = FillView()
    private var timer: Timer?
    private var startMs: Int64?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = TL.relaxed
        addSubview(label)
        rule.fill = TL.c(\.border, 0.6)
        addSubview(rule)
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        startMs = item.row.createdAt?.epochMs
        tick()
        updateTimer()
    }

    /// `formatWorkingTimer` (:3477-3490).
    private func tick() {
        guard let startMs else { label.text = "Working..."; return }
        let seconds = max(0, (Int64(context.now().timeIntervalSince1970 * 1000) - startMs) / 1000)
        label.text = "Working for " + (seconds < 60 ? "\(seconds)s" : formatDuration(Double(seconds) * 1000))
    }

    private func updateTimer() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        let run = visible && !isHiddenOrHasHiddenAncestor && startMs != nil
        if run, timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run {
            timer?.invalidate()
            timer = nil
        }
    }

    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: $0, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            }
        }
        updateTimer()
    }
    override func viewDidHide() { super.viewDidHide(); updateTimer() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateTimer() }

    override func height(forWidth width: CGFloat) -> CGFloat { 4 + 24 + 8 + 1 + 6 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 4, y: 4 + (24 - TL.relaxed) / 2, width: bounds.width - 8, height: TL.relaxed)
        rule.frame = NSRect(x: 0, y: 36, width: bounds.width, height: 1)
    }
}
