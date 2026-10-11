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
    private var tooltip: TooltipController?
    private var hoverInside = false

    init(_ row: ThreadRelationships.Lineage.Row, driver: String?, providerName: String, nowMs: Int64,
         mergeEnabled: Bool, mergeBusy: Bool, mergeTooltip: String, mergeLabel: String, stopping: Bool) {
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
        if row.canStop {
            let b = ButtonView(nil, icon: stopping ? .loaderCircle : .square, variant: .ghostDestructive, size: .iconXs)
            b.iconSize = 12
            b.isEnabled = !stopping
            b.setAccessibilityLabel("Stop subagent \(row.title)")
            _ = TooltipController.attach(to: b, text: "Stop subagent")
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

    private func restyle() {
        title.color = Themed.color(\.contrastForeground, 0.85)
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
        stop?.frame = NSRect(x: bounds.width - 4 - 24, y: midY - 12, width: 24, height: 24)
    }
}

/// `ThreadRelationshipsPanel` (ThreadRelationshipsControl.tsx:196-579) in the thread details card: a section
/// titled "Lineage" or "Lineage · N running" with the session menu, then the related rows, the active
/// subagents, and the settled ones folded under "Previous agents (N)". Each group shows 6 rows, then
/// "Show N more" adds 12 at a time.
public final class ThreadLineageSectionView: DSView {
    public static let initialCount = 6
    public static let pageCount = 12

    public var lineage = ThreadRelationships.Lineage() { didSet { if lineage != oldValue { rebuild() } } }
    /// The driver and display name of a provider instance, for the subagent glyphs.
    public var provider: ((String) -> (driver: String, name: String)?)?
    public var onOpen: ((ThreadId) -> Void)?
    public var onMerge: (() -> Void)?
    public var onStop: ((ThreadId) -> Void)?
    public var onDetach: (() -> Void)?
    /// Called when the section's height changes.
    public var onResize: (() -> Void)?
    public var mergeTargetTitle: String? { didSet { if mergeTargetTitle != oldValue { rebuild() } } }
    public var busy: Busy? { didSet { if busy != oldValue { rebuild() } } }
    public enum Busy: Equatable, Sendable { case merge, detach, stop(ThreadId) }

    private let heading = LabelView("Lineage", font: DSFont.ui(11, weight: .medium))
    private let more = ButtonView(nil, icon: .ellipsis, variant: .ghost, size: .iconXs)
    private let divider = CALayer()
    private let previousHeader = CollapsibleSectionHeaderView("Previous agents", tone: .muted, expanded: false)
    private let failedBadge = LabelView("", font: DSFont.ui(10))
    /// "Previous agents" is open (`ThreadLineageGroup`'s own state, folded at first).
    var previousExpanded = false {
        didSet { if previousExpanded != oldValue { previousHeader.isExpanded = previousExpanded; rebuild() } }
    }
    private var visible: [String: Int] = [:]
    private var rows: [ThreadLineageRowView] = []
    private var showMore: [(button: ThreadLineageShowMoreView, group: String)] = []
    private var layoutItems: [(view: NSView, height: CGFloat)] = []

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
        rows.forEach { $0.removeFromSuperview() }
        showMore.forEach { $0.button.removeFromSuperview() }
        rows = []
        showMore = []
        layoutItems = []
        heading.text = lineage.title
        more.isHidden = !lineage.canDetach
        more.isEnabled = busy != .merge && busy != .detach
        let nowMs = TimestampFormat.nowMs()
        let canMerge = lineage.mergeTarget != nil && lineage.mergeRunId != nil
        let mergeLabel = mergeTargetTitle.map { "Merge back to \($0)" } ?? "Merge back to source conversation"
        let mergeTooltip = lineage.mergeRunId == nil ? "Complete a run in this fork before merging it back"
            : mergeTargetTitle.map { "Merge this conversation back into \($0)" } ?? "Merge this conversation back into its source"
        func add(_ group: String, _ list: [ThreadRelationships.Lineage.Row]) {
            let count = visible[group] ?? Self.initialCount
            for r in list.prefix(count) {
                let p = r.agent.flatMap { provider?($0.providerInstanceId) } ?? r.child.flatMap { provider?($0.providerInstanceId.rawValue) }
                let driver = r.agent?.driver.isEmpty == false ? r.agent?.driver : p?.driver
                let stopping: Bool = if case .stop = busy { true } else { false }
                let v = ThreadLineageRowView(r, driver: driver, providerName: p?.name ?? driver ?? "", nowMs: nowMs,
                                             mergeEnabled: canMerge && busy == nil, mergeBusy: busy == .merge,
                                             mergeTooltip: mergeTooltip, mergeLabel: mergeLabel, stopping: stopping)
                v.action = { [weak self] in self?.onOpen?(r.threadId) }
                v.merge?.action = { [weak self] in self?.onMerge?() }
                v.stop?.action = { [weak self] in self?.onStop?(r.threadId) }
                addSubview(v)
                rows.append(v)
                layoutItems.append((v, 32))
            }
            let hidden = list.count - min(count, list.count)
            if hidden > 0 {
                let b = ThreadLineageShowMoreView(count: min(hidden, Self.pageCount))
                b.action = { [weak self] in self?.visible[group] = count + Self.pageCount; self?.rebuild() }
                addSubview(b)
                showMore.append((b, group))
                layoutItems.append((b, 32))
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
            layoutItems.append((previousHeader, 32))
            if previousExpanded { add("previous", lineage.previous) }
        }
        updateTimer()
        restyle()
        needsLayout = true
        onResize?()
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
        guard let wait = waits.min() else { LabelClock.shared.cancel(self); return }
        LabelClock.shared.schedule(self, in: Double(wait) / 1000) { [weak self] in
            guard let self else { return }
            let now = TimestampFormat.nowMs()
            self.rows.forEach { $0.tick(nowMs: now) }
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
        for (v, h) in layoutItems {
            v.frame = NSRect(x: 8, y: y, width: inner, height: h)
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
