import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The relationship icon (ThreadRelationshipIcon.tsx:46-89): a 16pt provider glyph for a subagent child, else
/// the fallback (corner-left-up for a parent, bot for a subagent, git-fork for a fork), with an 8pt status dot
/// at `-bottom-1 -right-1` ringed 2pt in `card`.
final class ThreadRelationshipIconView: DSView {
    private var glyph: NSView?
    private let dot = CALayer()
    private var tone = ThreadRelationships.Dot.muted

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.actions = ["backgroundColor": NSNull(), "borderColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        dot.cornerRadius = 4
        dot.borderWidth = 2
        layer?.masksToBounds = false
        layer?.addSublayer(dot)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(driver: String?, displayName: String, fallback: IconName, status: String?) {
        glyph?.removeFromSuperview()
        let muted = Themed.color(\.contrastMutedForeground)
        let v: NSView = driver.map { ProviderIcon.make(driver: $0, displayName: displayName, size: 16, color: muted) }
            ?? IconView(name: fallback, size: 16, strokeColor: muted)
        addSubview(v, positioned: .below, relativeTo: nil)
        glyph = v
        tone = ThreadRelationships.dot(status)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        glyph?.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        dot.frame = CGRect(x: 12, y: 12, width: 8, height: 8)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let fill: NSColor = switch tone {
        case .info: Themed.color(\.info)
        case .destructive: Themed.color(\.destructive)
        case .success: Themed.color(\.success)
        case .muted: Themed.color(\.mutedForeground, 0.45)
        }
        dot.backgroundColor = fill.cgColor(in: self)
        dot.borderColor = Themed.color(\.card).cgColor(in: self)
    }
}

/// One Lineage row (ThreadRelationshipsControl.tsx:370-571): a 32pt `ThreadDetailsControl` with the icon, the
/// title (`text-sm font-medium leading-4 text-foreground/85`), a hover arrow for plain threads, and one trailing
/// item: the agent's compact elapsed time, else the status label. The merge-back target is a split group with
/// the merge button and the status after it. An app-owned live subagent shows Stop on hover in place of the
/// trailing item.
final class ThreadLineageRowView: ControlView {
    let row: ThreadRelationships.Lineage.Row
    private let icon = ThreadRelationshipIconView()
    private let title = LabelView()
    private let arrow = IconView(name: .arrowRight, size: 12)
    private let trailing = LabelView()
    private let fill = CALayer()
    /// The merge-back target's split: the rule, the merge button and the status after it.
    private var rule: CALayer?
    private(set) var merge: ButtonView?
    private var mergeStatus: LabelView?
    private(set) var stop: ButtonView?
    /// A workflow row's disclosure: the split's 32pt secondary half and its chevron (ThreadLineageWorkflowRow.tsx:192-210).
    private(set) var disclosure: ButtonView?
    private var chevron: CAShapeLayer?
    private var tooltip: TooltipController?
    private var hoverInside = false

    init(_ row: ThreadRelationships.Lineage.Row, driver: String?, providerName: String, nowMs: Int64,
         mergeEnabled: Bool, mergeBusy: Bool, mergeTooltip: String, mergeLabel: String, stopping: Bool,
         workflowExpanded: Bool = false, canStopWorkflow: Bool = false) {
        self.row = row
        super.init(frame: .zero)
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        let fallback: IconName = row.isParent ? .cornerLeftUp : row.isSubagent ? .bot : .gitFork
        icon.configure(driver: row.isSubagent && !row.isParent ? driver : nil, displayName: providerName, fallback: fallback, status: row.status)
        title.text = row.title
        title.font = DSFont.ui(14, weight: .medium)
        title.lineHeight = 16
        trailing.font = DSFont.ui(11)
        trailing.lineHeight = 16
        arrow.alphaValue = 0
        arrow.isHidden = row.agent != nil
        trailing.text = Self.trailingText(row, nowMs: nowMs) ?? ""
        trailing.isHidden = trailing.text.isEmpty
        for v in [icon, title, arrow, trailing] as [NSView] { addSubview(v) }
        if row.isMergeTarget {
            let rule = CALayer()
            rule.actions = fill.actions
            layer?.addSublayer(rule)
            self.rule = rule
            let b = ButtonView(nil, icon: mergeBusy ? .loaderCircle : .gitMerge, variant: .ghost, size: .iconSm)
            b.iconSize = 12
            b.isEnabled = mergeEnabled && !mergeBusy
            b.setAccessibilityLabel(mergeLabel)
            tooltip = TooltipController.attach(to: b, text: mergeTooltip)
            tooltip?.placement = PopupPlacement(side: .left, align: .center, sideOffset: 4)
            addSubview(b)
            merge = b
            let s = LabelView(ThreadRelationships.statusLabel(row.status), font: DSFont.ui(11, weight: .medium))
            s.lineHeight = 16
            addSubview(s)
            mergeStatus = s
        }
        if row.workflow != nil {
            let rule = CALayer()
            rule.actions = fill.actions
            layer?.addSublayer(rule)
            self.rule = rule
            let b = ButtonView(nil, variant: .ghost, size: .iconSm)
            b.setAccessibilityLabel("\(workflowExpanded ? "Collapse" : "Expand") \(row.title)")
            b.setAccessibilityExpanded(workflowExpanded)
            addSubview(b)
            disclosure = b
            // `ChevronDownIcon size-3.5 text-muted-foreground transition-transform`, `rotate-180` while open.
            let c = CAShapeLayer()
            c.actions = ["position": NSNull(), "bounds": NSNull(), "strokeColor": NSNull(), "transform": NSNull(), "path": NSNull()]
            c.fillColor = nil
            c.lineWidth = 14.0 / 12
            c.lineCap = .round
            c.lineJoin = .round
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: 3.5, y: 5.25), CGPoint(x: 7, y: 8.75), CGPoint(x: 10.5, y: 5.25)])
            c.path = path
            c.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
            c.transform = CATransform3DMakeRotation(workflowExpanded ? .pi : 0, 0, 0, 1)
            layer?.addSublayer(c)
            chevron = c
            // A workflow row's trailing item is its elapsed time only; the status is screen-reader text (:542-561).
            if trailing.text == ThreadRelationships.statusLabel(row.status) { trailing.text = ""; trailing.isHidden = true }
        }
        if row.canStop || canStopWorkflow {
            let workflow = row.workflow != nil
            let b = ButtonView(nil, icon: stopping ? .loaderCircle : .square, variant: .ghostDestructive, size: .iconXs)
            b.iconSize = 12
            b.isEnabled = !stopping
            b.setAccessibilityLabel(workflow ? "Stop workflow \(row.title)" : "Stop subagent \(row.title)")
            _ = TooltipController.attach(to: b, text: workflow ? "Stop entire workflow" : "Stop subagent")
            b.alphaValue = 0
            addSubview(b)
            stop = b
        }
        isEnabled = !row.missing
        scalesWhenPressed = true
        setAccessibilityLabel("\(row.title) \(ThreadRelationships.statusLabel(row.status))")
        let hint = row.missing ? "This related thread is unavailable" : "Open \(row.relationship.lowercased()) in this chat"
        if !row.isMergeTarget {
            // Agents get the subagent hover card (SubagentTooltipContent), the rest the hint.
            let t = TooltipController.attach(to: self, text: row.agent == nil ? hint : "")
            if let agent = row.agent {
                let title = row.title
                t.content = { SubagentCardHoverView(SubagentCardPresentation(agent: agent, title: title)) }
            }
            t.placement = PopupPlacement(side: .left, align: .center, sideOffset: 4)
            t.delay = 0.2
        }
        restyle()
    }

    /// One trailing item (:448-462): an agent with a known time shows only that; otherwise the status label,
    /// except on the merge target, whose status sits after its merge button.
    static func trailingText(_ row: ThreadRelationships.Lineage.Row, nowMs: Int64) -> String? {
        if let a = row.agent, !row.failed,
           let ms = ThreadRelationships.subagentElapsedMs(status: a.status, startedAt: a.startedAt, completedAt: a.completedAt, nowMs: nowMs) {
            return ThreadRelationships.compactElapsed(seconds: Double(ms) / 1000)
        }
        return row.isMergeTarget ? nil : ThreadRelationships.statusLabel(row.status)
    }

    /// Updates the live elapsed time; returns true while it still ticks.
    func tick(nowMs: Int64) {
        guard row.agent != nil, let text = Self.trailingText(row, nowMs: nowMs), text != trailing.text else { return }
        trailing.text = text
        needsLayout = true
    }

    var ticks: Bool { row.agent.map { ThreadRelationships.isWorkActive($0.status) && $0.startedAt != nil } ?? false }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hoverChanged(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hoverChanged(false) }

    private func hoverChanged(_ on: Bool) {
        hoverInside = on
        // `opacity-0 transition-opacity group-hover:opacity-100` on the arrow (ThreadRelationshipsControl.tsx:446).
        // Stop replaces the trailing item at once: neither has a transition (:393, :452-458, :546).
        HoverReveal.fade([arrow], visible: on)
        if let stop {
            stop.alphaValue = on ? 1 : 0
            trailing.alphaValue = on ? 0 : 1
        }
        restyle()
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    /// Turns the chevron to the open or closed side over 150ms (`transition-transform`).
    func setWorkflowExpanded(_ open: Bool) {
        guard let chevron else { return }
        let angle: CGFloat = open ? .pi : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window != nil, !Motion.reduced { Motion.animate(chevron, keyPath: "transform.rotation.z", to: angle, duration: Motion.Durations.default) }
        chevron.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
        disclosure?.setAccessibilityLabel("\(open ? "Collapse" : "Expand") \(row.title)")
        disclosure?.setAccessibilityExpanded(open)
    }

    private func restyle() {
        title.color = Themed.color(\.contrastForeground, 0.85)
        chevron?.strokeColor = Themed.color(\.contrastMutedForeground).cgColor(in: self)
        arrow.strokeColor = Themed.color(\.contrastMutedForeground)
        trailing.color = row.failed ? Themed.color(\.destructive) : Themed.color(\.contrastMutedForeground)
        mergeStatus?.color = Themed.color(\.contrastMutedForeground)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // The split group fills as a whole on hover; a plain row fills itself.
        fill.backgroundColor = state.enabled && (hoverInside || state.hoverOrPressed) ? detailsHoverFill().cgColor(in: self) : nil
        rule?.backgroundColor = Themed.color(\.contrastBorder, 0.65).cgColor(in: self)
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let midY = bounds.height / 2
        // The control's 1pt transparent border, then `px-2.5 gap-2.5`.
        icon.frame = NSRect(x: 11, y: midY - 8, width: 16, height: 16)
        var right = bounds.width - 11
        if let merge, let mergeStatus, let rule {
            // The status after the group: `border ps-1 pe-2.5`; the 32pt merge part; the 16pt rule.
            let sw = ceil(mergeStatus.textWidth)
            mergeStatus.frame = NSRect(x: bounds.width - 11 - sw, y: midY - 8, width: sw, height: 16)
            merge.frame = NSRect(x: mergeStatus.frame.minX - 5 - 32, y: midY - 16, width: 32, height: 32)
            rule.frame = CGRect(x: merge.frame.minX - 1, y: midY - 8, width: 1, height: 16)
            right = rule.frame.minX - 11
        } else if let disclosure, let rule {
            disclosure.frame = NSRect(x: bounds.width - 32, y: midY - 16, width: 32, height: 32)
            rule.frame = CGRect(x: disclosure.frame.minX - 1, y: midY - 8, width: 1, height: 16)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chevron?.position = CGPoint(x: disclosure.frame.midX, y: midY)
            CATransaction.commit()
            right = rule.frame.minX - 11
        }
        if !trailing.isHidden {
            let w = ceil(trailing.textWidth)
            trailing.frame = NSRect(x: right - w, y: midY - 8, width: w, height: 16)
            right -= w + 10
        }
        if !arrow.isHidden {
            arrow.frame = NSRect(x: right - 12, y: midY - 6, width: 12, height: 12)
            right -= 12 + 10
        }
        title.frame = NSRect(x: 37, y: midY - 8, width: max(0, right - 37), height: 16)
        // A workflow's Stop sits `right-9` in the split group, left of the disclosure.
        stop?.frame = NSRect(x: bounds.width - (disclosure == nil ? 4 : 36) - 24, y: midY - 12, width: 24, height: 24)
    }
}

/// `ThreadRelationshipsPanel` (ThreadRelationshipsControl.tsx:196-579) in the thread details card: a section
/// titled "Lineage" or "Lineage · N running" with the session menu, then the related rows, the active
/// subagents, and the settled ones folded under "Previous agents (N)". Each group shows 6 rows, then
/// "Show N more" adds 12 at a time, in a list that stops at 13.5rem and scrolls (`ThreadLineageRowList`, :82-114).
public final class ThreadLineageSectionView: DSView {
    public static let initialCount = 6
    public static let pageCount = 12

    public var lineage = ThreadRelationships.Lineage() { didSet { if lineage != oldValue { rebuild() } } }
    /// The driver and display name of a provider instance, for the subagent glyphs.
    public var provider: ((String) -> (driver: String, name: String)?)?
    public var onOpen: ((ThreadId) -> Void)?
    public var onMerge: (() -> Void)?
    public var onStop: ((ThreadId) -> Void)?
    /// Stops a workflow: the row's thread and the coordinator subagent's id (`orchestration.stopWorkflow`).
    public var onStopWorkflow: ((ThreadId, String) -> Void)?
    public var onDetach: (() -> Void)?
    /// Called when the section's height changes.
    public var onResize: (() -> Void)?
    public var mergeTargetTitle: String? { didSet { if mergeTargetTitle != oldValue { rebuild() } } }
    public var busy: Busy? { didSet { if busy != oldValue { rebuild() } } }
    public enum Busy: Equatable, Sendable { case merge, detach, stop(ThreadId) }

    private let heading = LabelView("Lineage", font: DSFont.ui(11, weight: .medium))
    private let more = ButtonView(nil, icon: .ellipsis, variant: .ghost, size: .iconXs).menuTrigger()
    private let divider = CALayer()
    private let previousHeader = CollapsibleSectionHeaderView("Previous agents", tone: .muted, expanded: false)
    private let failedBadge = LabelView("", font: DSFont.ui(10))
    /// "Previous agents" is open (`ThreadLineageGroup`'s own state, folded at first).
    var previousExpanded = false {
        didSet { if previousExpanded != oldValue { previousHeader.isExpanded = previousExpanded; rebuild() } }
    }
    private var visible: [String: Int] = [:]
    /// Open workflow rows, and phases opened or closed by hand (a running phase opens itself until then).
    private var workflowsOpen: Set<ThreadId> = []
    private var phaseOpen: [String: Bool] = [:]
    /// The workflow row whose chevron turns on the next rebuild.
    private var turningWorkflow: ThreadId?
    private var members: [ThreadLineageWorkflowMemberView] = []
    private var phaseAccessories: [ThreadLineageWorkflowPhaseAccessory] = []
    private var rows: [ThreadLineageRowView] = []
    private var showMore: [(button: ThreadLineageShowMoreView, group: String)] = []
    /// Each group's row list, kept across rebuilds so a pushed update doesn't scroll it back to the top.
    private var lists: [String: ThreadLineageRowListView] = [:]
    /// The list `add` and `addWorkflow` fill.
    private var list: ThreadLineageRowListView?
    /// Each item's view and height, and how far it sits in (`ps-6.5` under an open workflow).
    private var layoutItems: [(view: NSView, height: CGFloat, indent: CGFloat)] = []

    public var isEmpty: Bool { lineage.isEmpty }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        divider.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(divider)
        heading.lineHeight = 16
        more.iconSize = 14
        more.iconColor = Themed.color(\.contrastForeground)
        more.setAccessibilityLabel("More thread actions")
        more.action = { [weak self] in self?.openMenu() }
        failedBadge.lineHeight = 10
        previousHeader.accessory = failedBadge
        previousHeader.onToggle = { [weak self] on in self?.previousExpanded = on }
        for v in [heading, more, previousHeader] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Lineage")
        rebuild()
    }

    /// `ThreadLineageGroup` keeps its own expanded state and window; a new thread starts them over.
    public func reset() {
        visible = [:]
        if previousExpanded { previousExpanded = false } else { rebuild() }
    }

    private func openMenu() {
        guard lineage.canDetach else { return }
        var item = MenuItem("Disconnect agent session", icon: .unplug)
        item.action = { [weak self] in self?.onDetach?() }
        MenuPopupView.show([item], from: more, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4), minimumWidth: 240)
    }

    private func rebuild() {
        lists.values.forEach { $0.removeAll() }
        showMore.forEach { $0.button.removeFromSuperview() }
        rows = []
        showMore = []
        layoutItems = []
        members = []
        phaseAccessories = []
        let turning = turningWorkflow
        turningWorkflow = nil
        heading.text = lineage.title
        more.isHidden = !lineage.canDetach
        more.isEnabled = busy != .merge && busy != .detach
        let nowMs = TimestampFormat.nowMs()
        let canMerge = lineage.mergeTarget != nil && lineage.mergeRunId != nil
        let mergeLabel = mergeTargetTitle.map { "Merge back to \($0)" } ?? "Merge back to source conversation"
        let mergeTooltip = lineage.mergeRunId == nil ? "Complete a run in this fork before merging it back"
            : mergeTargetTitle.map { "Merge this conversation back into \($0)" } ?? "Merge this conversation back into its source"
        var shownLists: Set<String> = []
        func add(_ group: String, _ list: [ThreadRelationships.Lineage.Row]) {
            guard !list.isEmpty else { return }
            let count = visible[group] ?? Self.initialCount
            let rowList = lists[group] ?? ThreadLineageRowListView()
            if lists[group] == nil { lists[group] = rowList; addSubview(rowList) }
            self.list = rowList
            shownLists.insert(group)
            for r in list.prefix(count) {
                let p = r.agent.flatMap { provider?($0.providerInstanceId) } ?? r.child.flatMap { provider?($0.providerInstanceId.rawValue) }
                let driver = r.agent?.driver.isEmpty == false ? r.agent?.driver : p?.driver
                let stopping: Bool = if case .stop = busy { true } else { false }
                let open = workflowsOpen.contains(r.threadId)
                // ThreadRelationshipsControl.tsx:491-495 in 2994: a running Claude workflow the provider owns.
                let canStopWorkflow = r.workflow?.status == "running" && r.agent?.origin == "provider_native" && driver == "claudeAgent"
                let v = ThreadLineageRowView(r, driver: driver, providerName: p?.name ?? driver ?? "", nowMs: nowMs,
                                             mergeEnabled: canMerge && busy == nil, mergeBusy: busy == .merge,
                                             mergeTooltip: mergeTooltip, mergeLabel: mergeLabel, stopping: stopping,
                                             workflowExpanded: turning == r.threadId ? !open : open, canStopWorkflow: canStopWorkflow)
                v.action = { [weak self] in self?.onOpen?(r.threadId) }
                v.merge?.action = { [weak self] in self?.onMerge?() }
                if let workflow = r.workflow {
                    v.stop?.action = { [weak self] in self?.onStopWorkflow?(r.threadId, workflow.coordinatorId) }
                    v.disclosure?.action = { [weak self] in
                        guard let self else { return }
                        if open { self.workflowsOpen.remove(r.threadId) } else { self.workflowsOpen.insert(r.threadId) }
                        self.turningWorkflow = r.threadId
                        self.rebuild()
                    }
                } else {
                    v.stop?.action = { [weak self] in self?.onStop?(r.threadId) }
                }
                rowList.add(v, height: 32, indent: 0)
                if turning == r.threadId { v.setWorkflowExpanded(open) }
                rows.append(v)
                if let workflow = r.workflow, let agent = r.agent, open {
                    addWorkflow(workflow, row: r, coordinator: agent, driver: driver, providerName: p?.name ?? driver ?? "", nowMs: nowMs)
                }
            }
            layoutItems.append((rowList, rowList.preferredHeight, 0))
            let hidden = list.count - min(count, list.count)
            if hidden > 0 {
                let b = ThreadLineageShowMoreView(count: min(hidden, Self.pageCount))
                b.action = { [weak self] in self?.visible[group] = count + Self.pageCount; self?.rebuild() }
                addSubview(b)
                showMore.append((b, group))
                layoutItems.append((b, 32, 0))
            }
        }
        add("related", lineage.related)
        add("active", lineage.active)
        previousHeader.isHidden = lineage.previous.isEmpty
        if !lineage.previous.isEmpty {
            previousHeader.title = previousExpanded ? "Previous agents" : "Previous agents (\(lineage.previous.count))"
            let failed = lineage.previous.filter(\.failed).count
            failedBadge.text = failed > 0 ? "\(failed) failed" : ""
            failedBadge.isHidden = failed == 0
            previousHeader.accessory = failed > 0 ? failedBadge : nil
            layoutItems.append((previousHeader, 32, 0))
            if previousExpanded { add("previous", lineage.previous) }
        }
        for (group, rowList) in lists where !shownLists.contains(group) {
            rowList.removeFromSuperview()
            lists[group] = nil
        }
        list = nil
        updateTimer()
        restyle()
        needsLayout = true
        onResize?()
    }

    /// An open workflow's phases (each a section header that a running phase opens by itself), their
    /// members, then the members with no phase (ThreadLineageWorkflowRow.tsx:212-262 in 2994).
    private func addWorkflow(_ workflow: SubagentWorkflowGroup, row: ThreadRelationships.Lineage.Row, coordinator: ProjectedSubagent,
                             driver: String?, providerName: String, nowMs: Int64) {
        let available = lineage.availableMembers
        func member(_ m: SubagentWorkflowGroup.Member) {
            let v = ThreadLineageWorkflowMemberView(m, coordinator: coordinator, driver: driver, providerName: providerName,
                                                    available: m.childThreadId.map(available.contains) ?? false, nowMs: nowMs)
            if let child = m.childThreadId { v.action = { [weak self] in self?.onOpen?(child) } }
            list?.add(v, height: 32, indent: 26)
            members.append(v)
        }
        let phases = workflow.phases.filter { !$0.members.isEmpty }
        for phase in phases {
            let key = "\(row.threadId.rawValue):\(phase.index)"
            let open = phaseOpen[key] ?? (phase.state == "running")
            let header = CollapsibleSectionHeaderView(phase.title, tone: phase.state == "running" ? .emphasized : .muted, expanded: open)
            let accessory = ThreadLineageWorkflowPhaseAccessory(phase, nowMs: nowMs)
            header.accessory = accessory
            header.setAccessibilityLabel("\(open ? "Collapse" : "Expand") \(phase.title) phase, \(phase.statusLabel)")
            header.onToggle = { [weak self] on in self?.phaseOpen[key] = on; self?.rebuild() }
            list?.add(header, height: 32, indent: 26)
            phaseAccessories.append(accessory)
            if open { phase.members.forEach(member) }
        }
        workflow.unphased.forEach(member)
        if phases.isEmpty && workflow.unphased.isEmpty {
            list?.add(ThreadLineageWorkflowEmptyView(), height: 28, indent: 26)
        }
    }

    /// Live agents' compact times ("45s", "12m", "1.5h") tick on the shared `LabelClock` when the next
    /// one changes and the section can be seen; nothing runs otherwise.
    private func updateTimer() {
        let now = TimestampFormat.nowMs()
        let waits = rows.compactMap { row -> Int64? in
            guard row.ticks, let a = row.row.agent,
                  let ms = ThreadRelationships.subagentElapsedMs(status: a.status, startedAt: a.startedAt, completedAt: a.completedAt, nowMs: now)
            else { return nil }
            return ThreadRelationships.msUntilElapsedChanges(ms, compact: true)
        }
        // An open workflow's live members and running phases show the long form ("12m 05s").
        let long = members.compactMap { $0.ticks ? $0.elapsedMs(now) : nil }
            + phaseAccessories.compactMap { $0.ticks ? $0.elapsedMs(now) : nil }
        guard let wait = (waits + long.map { ThreadRelationships.msUntilElapsedChanges($0, compact: false) }).min() else {
            LabelClock.shared.cancel(self); return
        }
        LabelClock.shared.schedule(self, in: Double(wait) / 1000) { [weak self] in
            guard let self else { return }
            let now = TimestampFormat.nowMs()
            self.rows.forEach { $0.tick(nowMs: now) }
            self.members.forEach { $0.tick(nowMs: now) }
            self.phaseAccessories.forEach { $0.tick(nowMs: now) }
            self.updateTimer()
        }
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); LabelClock.shared.visibilityChanged(); restyle() }
    public override func viewDidUnhide() { super.viewDidUnhide(); LabelClock.shared.visibilityChanged() }

    /// `border-t`, `px-2 pt-2 pb-2.5`: a 32pt heading with `mb-1`, then the rows.
    public var preferredHeight: CGFloat {
        isEmpty ? 0 : 1 + 8 + 32 + 4 + layoutItems.reduce(0) { $0 + $1.height } + 10
    }

    public override func layout() {
        super.layout()
        divider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        let inner = bounds.width - 16
        heading.frame = NSRect(x: 8 + 6, y: 1 + 8 + 8, width: max(0, inner - 12 - 28), height: 16)
        more.frame = NSRect(x: bounds.width - 8 - 6 - 24, y: 1 + 8 + 4, width: 24, height: 24)
        var y: CGFloat = 1 + 8 + 32 + 4
        for (v, h, indent) in layoutItems {
            v.frame = NSRect(x: 8 + indent, y: y, width: inner - indent, height: h)
            y += h
        }
    }

    private func restyle() {
        heading.color = Themed.color(\.contrastMutedForeground)
        failedBadge.color = Themed.color(\.destructiveForeground)
        needsDisplay = true
    }

    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() { divider.backgroundColor = Themed.color(\.contrastBorder, 0.65).cgColor(in: self) }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
}

/// "Show N more" (`ThreadLineageRowList`, :103-112): a 32pt row, plus icon, `text-sm font-medium
/// text-muted-foreground/70`, hover fills black 5.5% (white 7.5% dark) and lifts the text to `foreground/80`.
final class ThreadLineageShowMoreView: ControlView {
    private let icon = IconView(name: .plus, size: 16)
    private let label = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let fill = CALayer()

    init(count: Int) {
        super.init(frame: .zero)
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fill.cornerRadius = 8
        layer?.addSublayer(fill)
        label.text = "Show \(count) more"
        label.lineHeight = 20
        addSubview(icon)
        addSubview(label)
        scalesWhenPressed = false
        restyle()
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        let lit = state.hovered
        label.color = lit ? Themed.color(\.contrastForeground, 0.8) : Themed.color(\.contrastMutedForeground, 0.7)
        icon.strokeColor = label.color
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        fill.backgroundColor = state.hovered ? Themed.pick(light: Themed.black(0.055), dark: Themed.white(0.075)).cgColor(in: self) : nil
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        icon.frame = NSRect(x: 10, y: bounds.height / 2 - 8, width: 16, height: 16)
        label.frame = NSRect(x: 36, y: bounds.height / 2 - 10, width: max(0, bounds.width - 46), height: 20)
    }
}

/// `ThreadLineageRowList` (ThreadRelationshipsControl.tsx:82-114): a group's rows and open workflows in a
/// `max-h-[13.5rem] overflow-y-auto overscroll-contain` list, so a long group can't push the rest of the card
/// out of view. Plain overflow, so Chromium's styled bar rather than ScrollArea's.
final class ThreadLineageRowListView: DSView {
    static let maxHeight: CGFloat = 216
    let area: ScrollAreaView
    private let document = DSView()
    private var items: [(view: NSView, height: CGFloat, indent: CGFloat)] = []

    override init(frame frameRect: NSRect) {
        area = ScrollAreaView(documentView: document, scrollbars: .native)
        super.init(frame: frameRect)
        addSubview(area)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Related threads")
    }

    func add(_ view: NSView, height: CGFloat, indent: CGFloat) {
        document.addSubview(view)
        items.append((view, height, indent))
        needsLayout = true
    }

    func removeAll() {
        items.forEach { $0.view.removeFromSuperview() }
        items = []
    }

    var contentHeight: CGFloat { items.reduce(0) { $0 + $1.height } }
    var preferredHeight: CGFloat { min(contentHeight, Self.maxHeight) }

    override func layout() {
        super.layout()
        area.frame = bounds
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        var y: CGFloat = 0
        for (v, h, indent) in items {
            v.frame = NSRect(x: indent, y: y, width: bounds.width - indent, height: h)
            y += h
        }
    }
}
