import AppKit
import DesignSystem
import T3Protocol
import T3Store

// A Claude workflow's phases and members under its Lineage row (ThreadLineageWorkflowRow.tsx in 2994,
// b9afba59f). Servers before 2994 send no workflow, so none of this shows there.

/// One workflow member (`WorkflowMemberRow`, :57-118): a 32pt row with the coordinator's provider glyph and the
/// member's status dot, the label (`text-[13px] font-medium text-foreground/80`) and the member's elapsed time
/// (`text-2xs text-muted-foreground`). It opens the member's own thread when it has one.
final class ThreadLineageWorkflowMemberView: ControlView {
    let member: SubagentWorkflowGroup.Member
    private let icon = ThreadRelationshipIconView()
    private let title = LabelView("", font: DSFont.ui(13, weight: .medium))
    private let elapsed = LabelView("", font: DSFont.ui(11))
    private let fill = CALayer()

    init(_ member: SubagentWorkflowGroup.Member, coordinator: ProjectedSubagent, driver: String?, providerName: String,
         available: Bool, nowMs: Int64) {
        self.member = member
        super.init(frame: .zero)
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        icon.configure(driver: driver, displayName: providerName, fallback: .bot, status: member.status)
        title.text = member.title
        title.lineHeight = 16
        elapsed.lineHeight = 16
        elapsed.isHidden = true
        for v in [icon, title, elapsed] as [NSView] { addSubview(v) }
        tick(nowMs: nowMs)
        isEnabled = available
        scalesWhenPressed = true
        setAccessibilityLabel("Open \(member.title) chat")
        let agent = ProjectedSubagent(id: member.id, childThreadId: member.childThreadId, origin: "provider_native", driver: coordinator.driver,
                                      providerInstanceId: coordinator.providerInstanceId, title: member.title, model: member.model,
                                      status: member.status, progress: member.progress, result: member.result ?? member.error,
                                      startedAt: member.startedAt, completedAt: member.completedAt)
        let t = TooltipController.attach(to: self, text: "")
        let name = member.title
        t.content = { SubagentCardHoverView(SubagentCardPresentation(agent: agent, title: name)) }
        t.placement = PopupPlacement(side: .left, align: .center, sideOffset: 4)
        t.delay = 0.2
        restyle()
    }

    var ticks: Bool { ThreadRelationships.isWorkActive(member.status) && member.startedAt != nil }
    func elapsedMs(_ nowMs: Int64) -> Int64? {
        ThreadRelationships.subagentElapsedMs(status: member.status, startedAt: member.startedAt, completedAt: member.completedAt, nowMs: nowMs)
    }

    func tick(nowMs: Int64) {
        let text = member.startedAt == nil ? "" : elapsedMs(nowMs).map { ThreadRelationships.elapsed(seconds: Double($0) / 1000) } ?? ""
        guard text != elapsed.text else { return }
        elapsed.text = text
        elapsed.isHidden = text.isEmpty
        needsLayout = true
    }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        title.color = Themed.color(\.contrastForeground, 0.8)
        elapsed.color = Themed.color(\.contrastMutedForeground)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        fill.backgroundColor = state.enabled && state.hoverOrPressed ? detailsHoverFill().cgColor(in: self) : nil
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let midY = bounds.height / 2
        icon.frame = NSRect(x: 11, y: midY - 8, width: 16, height: 16)
        var right = bounds.width - 11
        if !elapsed.isHidden {
            let w = ceil(elapsed.textWidth)
            elapsed.frame = NSRect(x: right - w, y: midY - 8, width: w, height: 16)
            right -= w + 10
        }
        title.frame = NSRect(x: 37, y: midY - 8, width: max(0, right - 37), height: 16)
    }
}

/// A phase header's accessory (:224-237): "Failed", then "settled/n agents" and the phase's wall clock,
/// `gap-2`, in the header's tone.
final class ThreadLineageWorkflowPhaseAccessory: DSView {
    let phase: SubagentWorkflowGroup.Phase
    private let failed = LabelView("Failed", font: DSFont.ui(10))
    private let count = LabelView("", font: DSFont.ui(11))
    private let elapsed = LabelView("", font: DSFont.ui(11))

    init(_ phase: SubagentWorkflowGroup.Phase, nowMs: Int64) {
        self.phase = phase
        super.init(frame: .zero)
        failed.lineHeight = 10
        failed.isHidden = phase.statusLabel != "failed"
        count.lineHeight = 16
        elapsed.lineHeight = 16
        elapsed.isHidden = true
        count.text = "\(phase.settledCount)/\(phase.members.count) \(phase.members.count == 1 ? "agent" : "agents")"
        for v in [failed, count, elapsed] { addSubview(v) }
        tick(nowMs: nowMs)
        restyle()
    }

    var ticks: Bool { phase.elapsed.status == "running" && phase.elapsed.startedAt != nil }
    func elapsedMs(_ nowMs: Int64) -> Int64? {
        let e = phase.elapsed
        return ThreadRelationships.subagentElapsedMs(status: e.status, startedAt: e.startedAt, completedAt: e.completedAt, nowMs: nowMs)
    }

    func tick(nowMs: Int64) {
        let text = elapsedMs(nowMs).map { ThreadRelationships.elapsed(seconds: Double($0) / 1000) } ?? ""
        guard text != elapsed.text else { return }
        elapsed.text = text
        elapsed.isHidden = text.isEmpty
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private var parts: [LabelView] { [failed, count, elapsed].filter { !$0.isHidden } }

    override var intrinsicContentSize: NSSize {
        let w = parts.reduce(0) { $0 + ceil($1.textWidth) } + CGFloat(max(0, parts.count - 1)) * 8
        return NSSize(width: w, height: 16)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for p in parts {
            let w = ceil(p.textWidth), h: CGFloat = p === failed ? 10 : 16
            p.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
            x += w + 8
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        // The header's label tone (collapsible-section-header.tsx:5-10): emphasized while running, else muted.
        let tone = phase.state == "running" ? Themed.color(\.contrastSidebarForeground, 0.8) : Themed.color(\.contrastSidebarMutedForeground, 0.6)
        count.color = tone
        elapsed.color = tone
        failed.color = Themed.color(\.destructiveForeground)
    }
}

/// "No agents yet" under an open workflow with nothing to list (`px-2.5 py-1.5 text-2xs text-muted-foreground/70`).
final class ThreadLineageWorkflowEmptyView: DSView {
    private let label = LabelView("No agents yet", font: DSFont.ui(11))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(label)
        restyle()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    private func restyle() { label.color = Themed.color(\.contrastMutedForeground, 0.7) }
    override func layout() { super.layout(); label.frame = NSRect(x: 10, y: 6, width: max(0, bounds.width - 20), height: 16) }
}
