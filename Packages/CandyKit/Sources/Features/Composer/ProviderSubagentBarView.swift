import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `ProviderSubagentBar` (ProviderSubagentBar.tsx:18-93): stands in for the composer on a provider-native
/// subagent thread. The provider runs that conversation, so nothing can be sent; the bar names the model,
/// says how long it has worked, and leads back to the parent. `min-h-12 gap-3 py-2 ps-5 pe-2 text-sm`.
/// A live status ticks once a second while it can be seen (T3 writes the label from an interval, never re-rendering the view).
public final class ProviderSubagentBarView: DSView {
    public var driver: String? { didSet { if driver != oldValue { rebuildIcon() } } }
    public var providerName = "" { didSet { if providerName != oldValue { rebuildIcon() } } }
    public var modelLabel = "" { didSet { model.text = modelLabel; needsLayout = true } }
    /// Reasoning effort as the composer names it, when the subagent has one.
    public var effortLabel: String? { didSet { effort.text = effortLabel ?? ""; effort.isHidden = effortLabel == nil; needsLayout = true } }
    /// Nil until the subagent's root turn arrives.
    public var status: ThreadRelationships.SubagentStatus? { didSet { if status != oldValue { update() } } }
    /// Shows "Open parent" when set.
    public var onOpenParent: (() -> Void)? { didSet { openParent.isHidden = onOpenParent == nil; needsLayout = true } }

    private var icon: NSView?
    private let model = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let effort = LabelView("", font: DSFont.ui(14))
    private let statusLabel = LabelView("", font: SB.tabular(14))
    private let runsOnItsOwn = LabelView("Runs on its own", font: DSFont.ui(14))
    private let openParent = ButtonView("Open parent", icon: .arrowUpLeft, variant: .ghost, size: .sm)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [model, effort, statusLabel, runsOnItsOwn] { l.lineHeight = 20; addSubview(l) }
        effort.isHidden = true
        openParent.isHidden = true
        openParent.action = { [weak self] in self?.onOpenParent?() }
        addSubview(openParent)
        setAccessibilityRole(.group)
        update()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 48) }

    private func rebuildIcon() {
        icon?.removeFromSuperview()
        icon = driver.map { ProviderIcon.make(driver: $0, displayName: providerName, size: 16, color: Themed.color(\.contrastMutedForeground)) }
        icon.map(addSubview)
        needsLayout = true
    }

    private var live: Bool { status.map { ThreadRelationships.isWorkActive($0.status) } ?? false }

    private func update() {
        tick()
        // Announced once per transition; the ticking label is not.
        let announcement = ThreadRelationships.formatSubagentStatus(status.map { .init(status: $0.status, startedAt: nil, completedAt: $0.completedAt) }, nowMs: 0)
        let description = effortLabel.map { "\(modelLabel), \($0)" } ?? modelLabel
        setAccessibilityLabel("\(description) subagent: \(announcement)")
    }

    /// The live text shows whole seconds since `startedAt`, so it changes once a second; the shared
    /// `LabelClock` ticks it only while the bar can be seen.
    private func tick() {
        let now = TimestampFormat.nowMs()
        let text = ThreadRelationships.formatSubagentStatus(status, nowMs: now)
        if statusLabel.text != text { statusLabel.text = text; needsLayout = true }
        guard live, let start = status?.startedAt?.epochMs else { LabelClock.shared.cancel(self); return }
        LabelClock.shared.schedule(self, in: Double(1000 - max(0, now - start) % 1000) / 1000) { [weak self] in self?.tick() }
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); LabelClock.shared.visibilityChanged(); restyle() }
    public override func viewDidUnhide() { super.viewDidUnhide(); LabelClock.shared.visibilityChanged() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        model.color = Themed.color(\.contrastForeground)
        for l in [effort, statusLabel, runsOnItsOwn] { l.color = Themed.color(\.contrastMutedForeground) }
    }

    public override func layout() {
        super.layout()
        let midY = bounds.height / 2
        var right = bounds.width - 8
        if !openParent.isHidden {
            let s = openParent.intrinsicContentSize
            openParent.frame = NSRect(x: right - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
            right -= s.width + 12
        }
        // `max-sm:hidden`: below a 640 viewport.
        runsOnItsOwn.isHidden = (window?.contentView?.bounds.width ?? 1000) < 640
        if !runsOnItsOwn.isHidden {
            let w = ceil(runsOnItsOwn.textWidth)
            runsOnItsOwn.frame = NSRect(x: right - w, y: midY - 10, width: w, height: 20)
            right -= w + 12
        }
        var x: CGFloat = 20
        if let icon {
            icon.frame = NSRect(x: x, y: midY - 8, width: 16, height: 16)
            x += 16 + 8
        }
        // The model cluster shrinks first (`min-w-0 truncate`), then the status.
        let ew = effort.isHidden ? 0 : ceil(effort.textWidth)
        let sw = ceil(statusLabel.textWidth)
        let room = max(0, right - x)
        let mw = min(ceil(model.textWidth), max(0, room - (ew > 0 ? 8 + ew : 0) - 12 - min(sw, 120)))
        model.frame = NSRect(x: x, y: midY - 10, width: mw, height: 20)
        x += mw
        if ew > 0 {
            effort.frame = NSRect(x: x + 8, y: midY - 10, width: ew, height: 20)
            x += 8 + ew
        }
        x += 12
        statusLabel.frame = NSRect(x: x, y: midY - 10, width: max(0, min(sw, right - x)), height: 20)
    }
}
