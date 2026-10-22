import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// V2LifecycleRow.tsx:243-284, 420-530. Live state wins; terminal details prefer the result.
/// A notification card (`SubagentNotificationLink`, :335-398) draws the subagent at the event: the
/// outcome's status and label, and the event's time in place of the elapsed time.
struct SubagentCardPresentation {
    struct Event: Equatable { var status: String?; var label: String; var timestamp: String }
    var title: String
    /// The record's status (`liveStatus`): the hover card and the ticking elapsed time follow it.
    var liveStatus: String
    /// What the dot and tone show: the event's status (nil draws no dot), else the live one.
    var status: String?
    var statusLabel: String
    var event: Event?
    var driver: String
    var model: String?
    var detail: String?
    var hoverDetail: String?
    var child: ThreadId?
    var startedAt: T3Timestamp?
    var completedAt: T3Timestamp?
    /// A workflow member in the opening block (`WorkflowMemberRow`, WorkflowOpeningBlock.tsx:107-203): no status
    /// beside the title, and no detail line when the member has nothing to say.
    var memberRow = false

    init(_ p: ProjectedTurnItem, live: JSONValue? = nil) {
        self.init(title: p.item.title, fallbackStatus: p.item.status.rawValue, driver: p.string("driver"),
                  child: p.string("childThreadId"), event: nil) { live?[$0]?.stringValue ?? p.string($0) }
    }

    /// The card for a notification about a subagent the parent has a record of.
    init(record: JSONValue, event: Event?) {
        self.init(title: record["title"]?.stringValue, fallbackStatus: "completed", driver: record["driver"]?.stringValue,
                  child: record["childThreadId"]?.stringValue, event: event) { record[$0]?.stringValue }
    }

    /// A Lineage row's agent (ThreadLineageSectionView): the same hover card.
    init(agent a: ProjectedSubagent, title: String) {
        self.init(title: title, fallbackStatus: a.status, driver: a.driver, child: a.childThreadId?.rawValue, event: nil) { key in
            switch key {
            case "status": a.status
            case "model": a.model
            case "result": a.result
            case "progress": a.progress
            case "startedAt": a.startedAt?.raw
            case "completedAt": a.completedAt?.raw
            default: nil
            }
        }
    }

    /// A workflow member: the coordinator's driver, the member's own title, and its error, result or prompt once it
    /// settled, else its prompt, without backticks (WorkflowOpeningBlock.tsx:115-125).
    init(member m: SubagentWorkflowGroup.Member, driver: String?) {
        self.init(title: m.title, fallbackStatus: m.status, driver: driver, child: m.childThreadId?.rawValue, event: nil) { key in
            switch key {
            case "status": m.status
            case "model": m.model
            case "result": m.result ?? m.error
            case "progress": m.progress
            case "startedAt": m.startedAt?.raw
            case "completedAt": m.completedAt?.raw
            default: nil
            }
        }
        title = m.title
        memberRow = true
        let settled = ["completed", "failed", "cancelled", "interrupted"].contains(m.status)
        let raw = settled ? m.error ?? m.result ?? m.progress : m.progress
        let plain = raw?.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        detail = plain?.isEmpty == false ? plain : nil
    }

    private init(title raw: String?, fallbackStatus: String, driver: String?, child: String?, event: Event?, _ string: (String) -> String?) {
        title = ThreadRelationships.subagentDisplayTitle(raw ?? "Subagent")
        liveStatus = string("status") ?? fallbackStatus
        self.event = event
        status = event == nil ? liveStatus : event?.status
        statusLabel = event?.label ?? Self.label(liveStatus)
        self.driver = driver ?? ""
        model = string("model")
        self.child = child.map { ThreadId($0) }
        startedAt = string("startedAt").map { T3Timestamp($0) }
        completedAt = string("completedAt").map { T3Timestamp($0) }
        func trimmed(_ key: String) -> String? {
            let s = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return s?.isEmpty == false ? s : nil
        }
        let settled = ["completed", "failed", "cancelled", "interrupted"].contains(status ?? liveStatus)
        let raw = settled ? trimmed("result") ?? trimmed("progress") : trimmed("progress") ?? trimmed("result")
        let compact = raw?.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        hoverDetail = compact.map { $0.count > 280 ? String($0.prefix(280)).trimmingCharacters(in: .whitespaces) + "…" : $0 }
        detail = raw.flatMap { value in
            guard value.range(of: #"^Child task ended with status\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            let plain = value.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: #"(?m)^[ \t]*[-*][ \t]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return plain.isEmpty ? nil : plain
        }
    }

    /// `STATUS_VISUALS` labels.
    static func label(_ status: String) -> String {
        switch status {
        case "pending": "Queued"
        case "running": "Running"
        case "waiting": "Waiting"
        case "idle": "Idle · resumable"
        case "completed": "Completed"
        case "failed": "Failed"
        default: "Stopped"
        }
    }
    /// The small label after the title: only beside a detail, and never for a plain completed card.
    var showsStatusBesideTitle: Bool { !memberRow && detail != nil && (event != nil || status != "completed") }
    /// `SubagentElapsed` from the record, or the event's time.
    func trailing(now: Int64) -> String { event?.timestamp ?? elapsed(now: now) }
    /// Ticks only for a live card about a running agent.
    var ticks: Bool { event == nil && ThreadRelationships.isWorkActive(liveStatus) && startedAt != nil }
    func elapsed(now: Int64) -> String {
        ThreadRelationships.subagentElapsedMs(status: liveStatus, startedAt: startedAt, completedAt: completedAt, nowMs: now)
            .map { ThreadRelationships.elapsed(seconds: Double($0) / 1000) } ?? ""
    }
    /// `NOTIFICATION_OUTCOME_STATUS` and `NOTIFICATION_OUTCOME_LABEL` (V2LifecycleRow.tsx:335-353).
    static func notificationEvent(outcome: String?, timestamp: String) -> Event {
        switch outcome {
        case "completed": Event(status: "completed", label: "Finished", timestamp: timestamp)
        case "failed": Event(status: "failed", label: "Failed", timestamp: timestamp)
        case "cancelled": Event(status: "cancelled", label: "Stopped", timestamp: timestamp)
        case "updated": Event(status: nil, label: "Updated", timestamp: timestamp)
        default: Event(status: nil, label: "Finished", timestamp: timestamp)
        }
    }
}

extension SubagentCardPresentation {
    /// `notificationChildThreadId` (client-runtime/state/threadExecution.ts:437-452): the child a subagent or
    /// delegated-task notification reports on.
    static func notificationChild(_ e: WorkLogEntry) -> String? {
        guard let item = e.projectedItem?.item, item.type == .notification,
              let source = item["source"], ["subagent", "delegated_task"].contains(NotificationSource.kind(source)) else { return nil }
        return source["childThreadId"]?.stringValue
    }

    /// `SimpleWorkEntryRow` (MessagesTimeline.tsx:5362-5381): a notification about a child the parent has a
    /// record of draws as that subagent's card; without a record it stays a work line.
    @MainActor static func notificationCard(_ e: WorkLogEntry, records: [JSONValue]) -> SubagentCardPresentation? {
        guard let child = notificationChild(e),
              let record = records.first(where: { $0["childThreadId"]?.stringValue == child }) else { return nil }
        let time = e.createdAt.epochMs.map { TL.timeOfDay(Date(timeIntervalSince1970: Double($0) / 1000),
                                                          format: ClientSettingsStore.shared.current.string("timestampFormat")) } ?? ""
        let event = notificationEvent(outcome: e.projectedItem?.item["outcome"]?.stringValue, timestamp: time)
        // A subagent resumed since this notification shows its live status, not the outcome reported then (6670dc734e).
        let resumed = event.status != nil && resumedSince(status: record["status"]?.stringValue, startedAt: record["startedAt"]?.stringValue,
                                                          notifiedAt: e.createdAt)
        return SubagentCardPresentation(record: record, event: resumed ? nil : event)
    }

    /// `subagentResumedSince` (V2LifecycleRow.logic.ts:10-27): Claude resumes a finished subagent under the same id.
    /// An active one is always on a later run; a settled one is when it started after the notification.
    static func resumedSince(status: String?, startedAt: String?, notifiedAt: T3Timestamp) -> Bool {
        if let status, ThreadRelationships.isWorkActive(status) { return true }
        guard let started = startedAt.flatMap({ T3Timestamp($0).epochMs }), let notified = notifiedAt.epochMs else { return false }
        return started > notified
    }
}

/// A pooled row can contain adjacent subagents. Each link retains its own child target.
final class SubagentCardRowView: TimelineRowView {
    private(set) var links: [SubagentCardLinkView] = []
    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .event(let p, let group, _) = item.row.kind else { return }
        let agents = group ?? [p]
        while links.count > agents.count { let gone = links.removeLast(); gone.stop(); gone.removeFromSuperview() }
        while links.count < agents.count { let link = SubagentCardLinkView(); links.append(link); addSubview(link) }
        for (link, agent) in zip(links, agents) {
            let live = item.ui.subagentRecords.first { $0["id"]?.stringValue == agent.string("subagentId") }
            link.configure(SubagentCardPresentation(agent, live: live))
            link.action = { [weak self, weak link] in
                guard let child = link?.presentation?.child else { return }
                self?.context.model?.onOpenThread?(child)
            }
        }
        needsLayout = true
    }
    override func height(forWidth width: CGFloat) -> CGFloat { CGFloat(links.count) * SubagentCardLinkView.height + 8 }
    override func layout() {
        super.layout()
        for (i, link) in links.enumerated() { link.frame = NSRect(x: 0, y: CGFloat(i) * SubagentCardLinkView.height, width: bounds.width, height: SubagentCardLinkView.height) }
    }
    override func setContentVisible(_ visible: Bool) { links.forEach { $0.contentVisible = visible } }
    override func prepareForReuse() {
        super.prepareForReuse()
        links.forEach { $0.stop(); $0.removeFromSuperview() }
        links.removeAll()
    }
}

final class SubagentCardLinkView: ControlView {
    /// `py-1.5` around the 16pt title and the `text-2xs leading-relaxed` line.
    static let height: CGFloat = 46
    /// A member row without a detail line: `py-1.5` around the 24pt avatar.
    static func height(_ p: SubagentCardPresentation) -> CGFloat { p.memberRow && p.detail == nil ? 36 : height }
    private(set) var presentation: SubagentCardPresentation?
    private let avatar = FillView(), dot = FillView()
    private var glyph: NSView?
    private let title = LabelView("", font: TL.font(12, .medium))
    private let status = LabelView("", font: TL.font(10))
    private let detail = MiddleTruncateView("", font: TL.font(11))
    private let plainDetail = LabelView("", font: TL.font(11))
    private let elapsed = LabelView("", font: SB.tabular(12))
    private let chevron = IconView(name: .chevronRight, size: 14)
    private var tooltip: TooltipController?
    /// Dither, after Capy: a running agent's name follows a small teal dot grid instead of the status dot.
    private var dotGrid: DotGridSpinnerView?
    var contentVisible = true { didSet { if contentVisible { tick() } else { stop() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false
        avatar.radius = 12; dot.radius = 4
        title.lineHeight = 16; status.lineHeight = 14
        detail.lineHeight = 17.875; detail.showsTitle = false
        plainDetail.lineHeight = 17.875; elapsed.lineHeight = 16
        for v in [avatar, dot, title, status, detail, plainDetail, elapsed, chevron] { addSubview(v) }
        tooltip = TooltipController.attach(to: self, text: "", delay: 0.2)
        tooltip?.content = { [weak self] in SubagentCardHoverView(self?.presentation) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(_ p: SubagentCardPresentation) {
        presentation = p
        title.text = p.title
        status.text = p.showsStatusBesideTitle ? p.statusLabel : ""
        let text = p.detail ?? (p.memberRow ? "" : p.statusLabel)
        detail.value = text; plainDetail.text = text
        let path = text.contains("/") && !text.contains(" ")
        detail.isHidden = !path || text.isEmpty; plainDetail.isHidden = path || text.isEmpty
        chevron.isHidden = p.child == nil
        glyph?.removeFromSuperview()
        let v = p.driver.isEmpty ? IconView(name: .bot, size: 14, strokeColor: TL.c(\.mutedForeground)) : ProviderIcon.make(driver: p.driver, displayName: p.driver, size: 14)
        glyph = v; addSubview(v)
        setAccessibilityRole(p.child == nil ? .group : .button)
        setAccessibilityLabel(p.child == nil ? p.title : "Open \(p.title)")
        setAccessibilityHelp(p.statusLabel)
        tick(); restyle(); needsLayout = true
    }
    func stop() { LabelClock.shared.cancel(self); tooltip?.hide() }
    /// Writes the trailing time, then asks the shared `LabelClock` for a tick when that text next changes
    /// (each second below an hour, then each minute), only for a live card that is scrolled into view.
    private func tick() {
        let now = TimestampFormat.nowMs()
        let text = presentation?.trailing(now: now) ?? ""
        if elapsed.text != text { elapsed.text = text; needsLayout = true }
        guard let p = presentation, p.ticks, contentVisible,
              let ms = ThreadRelationships.subagentElapsedMs(status: p.liveStatus, startedAt: p.startedAt, completedAt: p.completedAt, nowMs: now)
        else { LabelClock.shared.cancel(self); return }
        LabelClock.shared.schedule(self, in: Double(ThreadRelationships.msUntilElapsedChanges(ms, compact: false)) / 1000) { [weak self] in self?.tick() }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); LabelClock.shared.visibilityChanged() }
    override func viewDidHide() { super.viewDidHide(); tooltip?.hide() }
    override func viewDidUnhide() { super.viewDidUnhide(); LabelClock.shared.visibilityChanged() }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    override func performAction() { if presentation?.child != nil { super.performAction() } }
    private func restyle() {
        let failed = presentation?.status == "failed"
        title.color = TL.c(\.foreground)
        let tone = failed ? TL.c(\.destructive) : TL.c(\.mutedForeground)
        status.color = tone; detail.color = tone; plainDetail.color = tone; elapsed.color = TL.c(\.mutedForeground)
        avatar.fill = TL.c(\.muted); avatar.border = TL.c(\.border, 0.7)
        let working = ["pending", "running", "waiting"].contains(presentation?.status ?? "")
        if working, ThemeRuntime.isDither(dark: effectiveAppearance.isDark) {
            if dotGrid == nil { let g = DotGridSpinnerView(); dotGrid = g; addSubview(g); needsLayout = true }
            dotGrid?.color = TL.c(\.accent)
        } else if let g = dotGrid {
            g.removeFromSuperview(); dotGrid = nil; needsLayout = true
        }
        dot.isHidden = presentation?.status == nil || dotGrid != nil
        dot.fill = switch presentation?.status {
        case "pending", "running", "waiting": TL.c(\.info)
        case "completed": TL.c(\.success)
        case "failed": TL.c(\.destructive)
        case "idle": TL.c(\.mutedForeground, 0.5)
        default: TL.c(\.mutedForeground, 0.6)
        }
        dot.layer?.shadowColor = TL.c(\.background).cgColor(in: self)
        dot.layer?.shadowOpacity = 1; dot.layer?.shadowRadius = 0
        dot.layer?.shadowOffset = .zero
        dot.layer?.shadowPath = CGPath(ellipseIn: CGRect(x: -2, y: -2, width: 12, height: 12), transform: nil)
        chevron.strokeColor = state.hovered ? TL.c(\.foreground) : TL.c(\.mutedForeground, 0.6)
        layer?.cornerRadius = 6
        layer?.backgroundColor = state.hovered && presentation?.child != nil ? TL.c(\.accent, 0.2).cgColor(in: self) : nil
    }
    override func layout() {
        super.layout()
        // Items center in the row; a member without a detail line is a 36pt row.
        let dy = (bounds.height - Self.height) / 2
        avatar.frame = NSRect(x: 8, y: 11 + dy, width: 24, height: 24)
        glyph?.frame = NSRect(x: 13, y: 16 + dy, width: 14, height: 14)
        dot.frame = NSRect(x: 24, y: 27 + dy, width: 8, height: 8)
        var right = bounds.width - 8
        if !chevron.isHidden { chevron.frame = NSRect(x: right - 14, y: 16 + dy, width: 14, height: 14); right -= 24 }
        let ew = ceil(elapsed.textWidth)
        elapsed.frame = NSRect(x: right - ew, y: 15 + dy, width: ew, height: 16); right -= ew + 10
        let lead: CGFloat = dotGrid == nil ? 0 : 16
        let available = max(0, right - 42), sw = status.text.isEmpty ? 0 : ceil(status.textWidth) + 8
        let tw = min(ceil(title.textWidth), max(0, available - sw - lead))
        let lone = detail.isHidden && plainDetail.isHidden
        let titleY: CGFloat = lone ? (bounds.height - 16) / 2 : 6
        dotGrid?.frame = NSRect(x: 40, y: titleY, width: 14, height: 16)
        title.frame = NSRect(x: 42 + lead, y: titleY, width: tw, height: 16)
        status.frame = NSRect(x: 42 + lead + tw + 8, y: 8, width: max(0, sw - 8), height: 14)
        detail.frame = NSRect(x: 42, y: 22, width: available, height: 17.875)
        plainDetail.frame = detail.frame
    }
}

/// ThreadHoverCard.tsx and SubagentTooltipContent.tsx: title, model, status, elapsed and preview.
// ponytail: no provider catalog name, workspace, branch, effort or speed lines (SubagentTooltipContent.tsx:62-140); add them with the provider list in the timeline context
final class SubagentCardHoverView: DSView, PopupContent {
    private let box = BoxDecorationLayer()
    private let title = LabelView("", font: TL.font(12, .medium))
    private let model = LabelView("", font: TL.font(12))
    private let status = LabelView("", font: TL.font(12, .medium))
    private let elapsed = LabelView("", font: SB.tabular(12))
    private let preview = MiddleTruncateView("", font: TL.font(12))
    private var glyph: NSView?
    private var statusGlyph: IconView?
    private let terminal = IconView(name: .terminal, size: 12)
    init(_ p: SubagentCardPresentation?) {
        super.init(frame: .zero)
        box.host = self; layer?.addSublayer(box)
        var style = BoxStyle(); style.radius = 8; style.fill = PopupSurface.glassFill
        style.border = Themed.color(\.contrastForeground, 0.1)
        style.shadows = [BoxShadow(y: 20, blur: 25, spread: -5, color: Themed.black(0.25)), BoxShadow(y: 8, blur: 10, spread: -6, color: Themed.black(0.25))]
        box.boxStyle = style; box.outset = 32
        title.text = p?.title ?? "Subagent"; title.lineHeight = 15
        // `resolveSubagentMetadata` without a provider catalog: `formatModelSlugName`.
        model.text = p?.model.map(ThreadRelationships.modelSlugName) ?? "Not reported"; model.lineHeight = 16
        status.text = p?.liveStatus.replacingOccurrences(of: "_", with: " ").capitalized ?? ""; status.lineHeight = 16
        elapsed.text = p?.elapsed(now: TimestampFormat.nowMs()) ?? ""; elapsed.lineHeight = 16
        preview.value = p?.hoverDetail ?? ""; preview.lineHeight = 16; preview.showsTitle = false
        terminal.isHidden = preview.value.isEmpty
        let live = p?.liveStatus ?? ""
        let tone = live == "failed" ? TL.c(\.destructive) : live == "completed" ? TL.c(\.success) : ThreadRelationships.isWorkActive(live) ? TL.c(\.info) : TL.c(\.mutedForeground)
        status.color = tone
        statusGlyph = IconView(name: live == "completed" ? .check : live == "failed" ? .circleX : .circleDashed, size: 12, strokeColor: tone)
        glyph = (p?.driver.isEmpty ?? true) ? IconView(name: .bot, size: 12, strokeColor: TL.c(\.mutedForeground)) : ProviderIcon.make(driver: p?.driver ?? "", displayName: p?.driver ?? "", size: 12, color: TL.c(\.mutedForeground))
        // `grayscale opacity-60` (SubagentTooltipContent.tsx:135): Claude's #d97757 turns gray, the rest keep their color.
        if let icon = glyph as? IconView, icon.name == .brandClaudeAI {
            for l in icon.shapeLayers where l.fillColor != nil { l.fillColor = NSColor(srgbRed: 0.537, green: 0.537, blue: 0.537, alpha: 1).cgColor }
        }
        if !(p?.driver.isEmpty ?? true) { glyph?.alphaValue = 0.6 }
        for v in [title, model, status, elapsed, preview, terminal, glyph!, statusGlyph!] { addSubview(v) }
        title.color = TL.c(\.foreground); model.color = TL.c(\.foreground, 0.75)
        elapsed.color = TL.c(\.mutedForeground); preview.color = TL.c(\.mutedForeground)
    }
    /// Content-sized up to `max-w-80` (ThreadHoverCard.tsx:10, 26): the widest of the title, the model, the status
    /// row (`justify-between gap-4`) and the preview, plus the card's padding.
    var popupSize: CGSize {
        let statusRow = 31 + ceil(status.textWidth) + 16 + ceil(elapsed.textWidth) + 13
        let previewRow = preview.value.isEmpty ? 0 : ceil(preview.intrinsicContentSize.width) + 48
        let width = max(ceil(title.textWidth) + 26, ceil(model.textWidth) + 48, statusRow, previewRow)
        return CGSize(width: min(320, width), height: preview.value.isEmpty ? 88 : 110)
    }
    override func layout() {
        super.layout(); box.layout(boxSize: bounds.size)
        title.frame = NSRect(x: 13, y: 13, width: bounds.width - 26, height: 15)
        glyph?.frame = NSRect(x: 15, y: 38, width: 12, height: 12)
        model.frame = NSRect(x: 35, y: 36, width: bounds.width - 48, height: 16)
        statusGlyph?.frame = NSRect(x: 15, y: 60, width: 12, height: 12)
        status.frame = NSRect(x: 31, y: 58, width: 120, height: 16)
        elapsed.frame = NSRect(x: bounds.width - 100, y: 58, width: 87, height: 16); elapsed.alignment = .right
        terminal.frame = NSRect(x: 15, y: 82, width: 12, height: 12)
        preview.frame = NSRect(x: 35, y: 80, width: bounds.width - 48, height: 16)
    }
}
