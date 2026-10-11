import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `ThreadAutomationsPanel`: the thread details section listing tasks bound to this thread, from the live
/// task list. Each row: calendar clock with a run status dot, title, `schedule · next in 5m` (or paused),
/// Edit, Run now (not for webhooks) and the pause switch. Hidden when nothing is bound and nothing failed.
public final class ThreadAutomationsView: DSView {
    public var tasks: [ScheduledTask] = [] { didSet { rebuild() } }
    public var error: String? { didSet { rebuild() } }
    public var busyTaskId: String? { didSet { rebuild() } }
    public var canOperate = true { didSet { rebuild() } }
    public var onManage: (() -> Void)?
    public var onEdit: ((ScheduledTask) -> Void)?
    public var onRun: ((ScheduledTask) -> Void)?
    public var onToggle: ((ScheduledTask, Bool) -> Void)?

    private let title = LabelView("Automations", font: DSFont.ui(11, weight: .medium), color: Themed.color(\.mutedForeground))
    private let manage = ButtonView(nil, icon: .settings2, variant: .ghost, size: .iconXs)
    private let errorLabel = LabelView("", font: DSFont.ui(11), color: Themed.color(\.destructive))
    private var rows: [ThreadAutomationRow] = []

    public var isEmpty: Bool { error == nil && tasks.isEmpty }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineHeight = 24
        errorLabel.lineHeight = 16
        manage.iconSize = 14
        manage.setAccessibilityLabel("Manage scheduled tasks")
        _ = TooltipController.attach(to: manage, text: "Manage scheduled tasks")
        manage.action = { [weak self] in self?.onManage?() }
        for v in [title, manage, errorLabel] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Automations")
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        let nowMs = TimestampFormat.nowMs()
        rows = tasks.map { t in
            let r = ThreadAutomationRow(task: t, nowMs: nowMs, busy: busyTaskId != nil, canOperate: canOperate)
            r.edit.action = { [weak self] in self?.onEdit?(t) }
            r.run?.action = { [weak self] in self?.onRun?(t) }
            r.toggle.onChange = { [weak self] on in self?.onToggle?(t, on) }
            addSubview(r)
            return r
        }
        errorLabel.text = error.map { "Could not load automations: \($0)" } ?? ""
        errorLabel.isHidden = error == nil
        needsLayout = true
        superview?.needsLayout = true
    }

    /// `px-2 pt-2 pb-2.5`: a 24pt heading, the error line, then 44pt rows.
    public var preferredHeight: CGFloat { isEmpty ? 0 : 8 + 24 + (error == nil ? 0 : 22) + CGFloat(rows.count) * 44 + 10 }

    public override func layout() {
        super.layout()
        let inner = bounds.width - 16
        title.frame = NSRect(x: 8 + 4, y: 8, width: inner - 32, height: 24)
        manage.frame = NSRect(x: bounds.width - 8 - 24, y: 8, width: 24, height: 24)
        var y: CGFloat = 32
        if error != nil { errorLabel.frame = NSRect(x: 18, y: y + 3, width: inner - 20, height: 16); y += 22 }
        for r in rows { r.frame = NSRect(x: 8, y: y, width: inner, height: 44); y += 44 }
    }
}

final class ThreadAutomationRow: DSView {
    private let icon = IconView(name: .calendarClock, size: 16)
    private let dot = DSView()
    private let title: LabelView
    private let detail: LabelView
    let edit = ButtonView(nil, icon: .pencil, variant: .ghost, size: .iconXs)
    let run: ButtonView?
    let toggle: SwitchView
    private let status: String

    init(task t: ScheduledTask, nowMs: Int64, busy: Bool, canOperate: Bool) {
        status = t.lastRunStatus
        title = LabelView(t.title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground, 0.8))
        title.lineHeight = 20
        let tail = t.enabled && t.nextRunAt != nil ? " · next \(ScheduledTaskLogic.relativeLabel(t.nextRunAt, nowMs: nowMs))" : t.enabled ? "" : " · paused"
        detail = LabelView(ScheduledTaskLogic.scheduleLabel(t.schedule) + tail, font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
        detail.lineHeight = 16
        run = t.schedule.isWebhook ? nil : ButtonView(nil, icon: .play, variant: .ghost, size: .iconXs)
        toggle = SwitchView(isOn: t.enabled, size: .sm)
        super.init(frame: .zero)
        icon.strokeColor = Themed.color(\.mutedForeground)
        dot.layer?.cornerRadius = 3
        for b in [edit] + (run.map { [$0] } ?? []) { b.iconSize = 14 }
        edit.setAccessibilityLabel("Edit \(t.title)")
        _ = TooltipController.attach(to: edit, text: "Edit automation")
        if let run {
            run.setAccessibilityLabel("Run \(t.title) now")
            run.isEnabled = canOperate && !busy && t.lastRunStatus != "running"
            _ = TooltipController.attach(to: run, text: "Run now")
        }
        toggle.isEnabled = canOperate && !busy
        toggle.setAccessibilityLabel(t.enabled ? "Pause \(t.title)" : "Resume \(t.title)")
        for v in [icon, dot, title, detail, edit, toggle] as [NSView] { addSubview(v) }
        run.map(addSubview)
    }

    /// `STATUS_DOT_CLASS`.
    private var dotColor: NSColor {
        switch status {
        case "running": Themed.base("sky-500")
        case "succeeded": Themed.base("emerald-500")
        case "failed": Themed.color(\.destructive)
        default: Themed.color(\.mutedForeground, 0.4)
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); dot.layer?.backgroundColor = dotColor.cgColor(in: self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); viewDidChangeEffectiveAppearance() }

    override func layout() {
        super.layout()
        // `py-1.5 gap-2.5 px-2.5`.
        icon.frame = NSRect(x: 10, y: 14, width: 16, height: 16)
        dot.frame = NSRect(x: 10 + 16 - 2, y: 14 - 4, width: 6, height: 6)
        let ts = toggle.intrinsicContentSize
        var right = bounds.width - 10
        toggle.frame = NSRect(x: right - ts.width, y: (44 - ts.height) / 2, width: ts.width, height: ts.height)
        right -= ts.width + 10
        for b in [run, edit].compactMap({ $0 }) {
            b.frame = NSRect(x: right - 24, y: 10, width: 24, height: 24)
            right -= 24 + 10
        }
        let x: CGFloat = 36
        title.frame = NSRect(x: x, y: 6, width: max(0, right - x), height: 20)
        detail.frame = NSRect(x: x, y: 24, width: max(0, right - x), height: 16)
    }
}
