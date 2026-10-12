import AppKit
import DesignSystem
import T3Protocol

/// contextWindow.ts:26-176. Live turn usage wins over provider usage and compaction history.
public struct ThreadContextWindowUsage: Equatable, Sendable {
    public var used: Double
    public var maximum: Double?
    public var total: Double?
    public var cost: Double?
    public var currency: String = "USD"
    public var autoCompactThreshold: Double? = nil
    public var automatically: Bool
    /// When the usage last changed; the resume compaction offer waits the prompt cache's life from it.
    public var updatedAt: Date? = nil
    /// The provider's prompt cache lifetime, on a live report from 2994 servers (c727d1219, orchestrationV2.ts:1066).
    public var promptCacheTtlMs: Double? = nil
    public var percentage: Double? { maximum.flatMap { $0 > 0 ? min(100, max(0, used / $0 * 100)) : nil } }
    public static func derive(_ projection: ThreadProjection?) -> Self? {
        guard let projection else { return nil }
        func date(_ value: JSONValue?) -> Date? { value?.stringValue.flatMap { T3Timestamp($0).date } }
        func read(_ json: JSONValue, live: Bool, updatedAt: Date?) -> Self? {
            guard let used = json["usedTokens"]?.doubleValue, used.isFinite else { return nil }
            return Self(used: max(0, used), maximum: json["maxTokens"]?.doubleValue,
                        total: live ? nil : json["totalProcessedTokens"]?.doubleValue,
                        cost: live ? nil : (json["cost"]?.doubleValue ?? json["cost"]?["amount"]?.doubleValue),
                        currency: json["cost"]?["currency"]?.stringValue ?? "USD",
                        autoCompactThreshold: json["autoCompactThreshold"]?.doubleValue, automatically: live || json["compactsAutomatically"]?.boolValue == true,
                        updatedAt: updatedAt, promptCacheTtlMs: live ? json["promptCacheTtlMs"]?.doubleValue : nil)
        }
        // `latestProviderTurnTokenUsage` (lib/contextWindow.ts:29-41 in 2994): the newest report by
        // `updatedAt`, ties to the later entry, since live upserts append.
        var latest: (usage: JSONValue, at: Date?)?
        for turn in projection.providerTurns {
            guard let usage = turn["tokenUsage"] else { continue }
            let at = date(usage["updatedAt"])
            if latest == nil || (at ?? .distantPast) >= (latest!.at ?? .distantPast) { latest = (usage, at) }
        }
        if let latest, let result = read(latest.usage, live: true, updatedAt: latest.at) { return result }
        if let provider = projection.providerThreads.first(where: { $0["id"]?.stringValue == projection.thread.activeProviderThreadId }),
           let usage = provider["contextUsage"], let result = read(usage, live: false, updatedAt: date(provider["updatedAt"])) { return result }
        for entry in projection.visibleTurnItems.reversed() {
            let item = entry.item.raw
            if item["type"]?.stringValue == "compaction", let used = item["afterTokenCount"]?.doubleValue, used >= 0 {
                return Self(used: used, total: item["beforeTokenCount"]?.doubleValue, automatically: true,
                            updatedAt: date(item["startedAt"]) ?? date(item["updatedAt"]))
            }
        }
        return nil
    }
    public static func tokens(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value < 1_000 { return String(Int(value.rounded())) }
        if value < 10_000 { return decimal(value / 1_000) + "k" }
        if value < 1_000_000 { return String(Int((value / 1_000).rounded())) + "k" }
        return decimal(value / 1_000_000) + "m"
    }
    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }
    public var percentageLabel: String? { percentage.map { $0 < 10 ? Self.decimal($0) + "%" : "\(Int($0.rounded()))%" } }
}

/// ContextWindowMeter.tsx:42-211. No timer or idle animation; the stream changes the ring.
public final class ThreadContextWindowMeterView: ControlView {
    public var usage: ThreadContextWindowUsage? { didSet {
        guard usage != oldValue else { return }
        needsDisplay = true
        updateArc(animated: oldValue != nil)
        setAccessibilityLabel(summary)
        setAccessibilityValue(usage?.percentage.map { NSNumber(value: $0) })
        setAccessibilityElement(usage != nil)
        if usage == nil { closeDetails() } else { refreshDetails() }
    } }
    /// Runs Compact context. The popup offers the button only while `compactOffered` (ChatComposer.tsx:7673:
    /// the selected provider has a `compact` command).
    public var onCompact: (@MainActor () -> Void)?
    public var compactOffered = false
    private weak var detailsPopup: OpenPopup?
    private var hoverWork: DispatchWorkItem?
    private var pointerInDetails = false
    public var modelDisplayName: String?
    /// The Compact context button is disabled; `compactDisabledReason` shows under it when set.
    public var compactDisabled = false
    public var compactDisabledReason: String?
    /// `ContextWindowMeterPlaceholder` (ContextWindowMeter.tsx:177-180): with no usage yet, the composer
    /// still holds the meter's 28pt slot so the attach button does not move when it arrives.
    public var reserved = false
    public override var wantsUpdateLayer: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    public var summary: String {
        guard let usage else { return "Context Window" }
        return usage.percentageLabel.map { "Context window \($0) used" } ?? "Context window \(ThreadContextWindowUsage.tokens(usage.used)) tokens used"
    }
    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
        action = { [weak self] in self?.showDetails() }
        arc.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "strokeEnd": NSNull(), "strokeColor": NSNull(), "hidden": NSNull()]
        arc.fillColor = nil
        arc.lineWidth = 2.5
        arc.lineCap = .round
        arc.isHidden = true
        layer?.addSublayer(arc)
    }

    /// The usage arc as a layer, so its `stroke-dashoffset` and `stroke` changes run 500ms `ease-out`
    /// (ContextWindowMeter.tsx:82; Tailwind's `ease-out` is `cubic-bezier(0, 0, .2, 1)`).
    private let arc = CAShapeLayer()
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)

    private func updateArc(animated: Bool) {
        let fraction = min(1, max(0, (usage?.percentage ?? 0) / 100))
        let color = (fraction > 0.9 ? Themed.color(\.destructive) : Themed.color(\.mutedForeground, 0.72)).cgColor(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, !arc.isHidden, fraction > 0, window != nil, !Motion.reduced {
            Motion.animate(arc, keyPath: "strokeEnd", to: fraction, duration: 0.5, timing: Self.easeOut)
            Motion.animate(arc, keyPath: "strokeColor", to: color, duration: 0.5, timing: Self.easeOut)
        }
        arc.isHidden = fraction <= 0
        arc.strokeEnd = fraction
        arc.strokeColor = color
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateArc(animated: false)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let usage else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 9.75 * 20 / 24
        ctx.setLineWidth(2.5)
        ctx.setStrokeColor(Themed.color(\.mutedForeground, 0.24).cgColor(in: self))
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    public override func layout() {
        super.layout()
        // A full turn from the top, clockwise on screen (y grows downward here); `strokeEnd` is the share used.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(center: center, radius: 9.75 * 20 / 24, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.path = path
        CATransaction.commit()
    }
    // MARK: Popover (`PopoverTrigger openOnHover delay={150} closeDelay={onCompact ? 150 : 0}`, ContextWindowMeter.tsx:43-47)

    /// One-shot hover delays, as `TooltipController` does; nothing runs while the pointer is elsewhere.
    static let openDelay: TimeInterval = 0.15
    var closeDelay: TimeInterval { compactOffered ? 0.15 : 0 }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hoverWork?.cancel()
        guard usage != nil, detailsPopup == nil else { return }
        schedule(Self.openDelay) { $0.showDetails() }
    }
    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverWork?.cancel()
        scheduleClose()
    }
    private func schedule(_ delay: TimeInterval, _ body: @escaping @MainActor (ThreadContextWindowMeterView) -> Void) {
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if let self { body(self) } } }
        hoverWork = work
        if delay == 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }
    private func scheduleClose() {
        guard detailsPopup != nil else { return }
        schedule(closeDelay) { meter in
            guard !meter.pointerInDetails, let window = meter.window else { return }
            if meter.bounds.contains(meter.convert(window.mouseLocationOutsideOfEventStream, from: nil)) { return }
            meter.closeDetails()
        }
    }
    public override func viewDidMoveToWindow() {
        if window == nil { closeDetails() }
        super.viewDidMoveToWindow()
    }
    func closeDetails() {
        hoverWork?.cancel()
        hoverWork = nil
        guard let open = detailsPopup else { return }
        detailsPopup = nil
        pointerInDetails = false
        open.content.popupHost?.close(open, returnFocus: false)
    }
    /// The open popup's content, for tests.
    var detailsView: ThreadContextWindowDetailsView? { (detailsPopup?.content as? PopoverView)?.content as? ThreadContextWindowDetailsView }

    /// Shows what changed in an open popup: the button turns disabled with its reason once a compact
    /// starts, as T3's popover re-renders while it stays open.
    private func refreshDetails() {
        guard let open = detailsPopup, let usage, let content = detailsView else { return }
        guard content.configure(usage: usage, model: modelDisplayName, compactOffered: compactOffered,
                                disabled: compactDisabled, reason: compactDisabledReason) else { return }
        open.content.invalidateIntrinsicContentSize()
        open.content.popupHost?.reposition(open)
    }

    func showDetails() {
        hoverWork?.cancel()
        guard detailsPopup == nil, let usage, let host = popupHost else { return }
        let content = ThreadContextWindowDetailsView()
        _ = content.configure(usage: usage, model: modelDisplayName, compactOffered: compactOffered,
                              disabled: compactDisabled, reason: compactDisabledReason)
        content.onPointerInside = { [weak self] inside in
            self?.pointerInDetails = inside
            if inside { self?.hoverWork?.cancel() } else { self?.scheduleClose() }
        }
        content.onCompact = { [weak self] in self?.onCompact?() }
        let popover = PopoverView(content: content, padding: .none, width: .sm, tooltipStyle: true)
        detailsPopup = host.open(popover, trigger: self, placement: PopupPlacement(side: .top, align: .end, sideOffset: 4),
                                 motion: .popover, pressesTrigger: false, returnsFocus: false, passive: true)
        detailsPopup?.onClose = { [weak self] in self?.detailsPopup = nil; self?.pointerInDetails = false }
    }

    /// Settings the open popup reads; the controller sets them on every refresh.
    public func setCompactState(offered: Bool, disabled: Bool, reason: String?, model: String?) {
        guard offered != compactOffered || disabled != compactDisabled || reason != compactDisabledReason || model != modelDisplayName else { return }
        compactOffered = offered; compactDisabled = disabled; compactDisabledReason = reason; modelDisplayName = model
        refreshDetails()
    }
}

/// The popup (ContextWindowMeter.tsx:89-171): `p-3` and `gap-2` rows. A header with the share used, a
/// 6pt bar, Total processed and Cost rows, the auto-compaction note, then Compact context and the
/// reason it is disabled.
final class ThreadContextWindowDetailsView: DSView {
    var onPointerInside: ((Bool) -> Void)?
    var onCompact: (@MainActor () -> Void)?
    private let title = LabelView("Context Window", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
    private let figure = LabelView("", font: SB.tabular(11), color: Themed.color(\.contrastSecondaryLabel))
    private let track = FillView(), bar = FillView()
    private var rows: [(LabelView, LabelView)] = []
    private let note = TextBlockView("", font: DSFont.ui(11, weight: .medium), lineHeight: 16, color: Themed.color(\.contrastSecondaryLabel))
    private let button = ButtonView("Compact context", icon: .minimize2, variant: .outline, size: .xs)
    private let reasonText = TextBlockView("", font: DSFont.ui(11), lineHeight: 16, color: Themed.color(\.contrastSecondaryLabel))
    private var fraction: CGFloat = 0
    private var model: Model?
    static let inset: CGFloat = 12, width: CGFloat = 256 - 2 - 2 * 12

    private struct Model: Equatable {
        var usage: ThreadContextWindowUsage, model: String?, compactOffered: Bool, disabled: Bool, reason: String?
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [title, figure] { label.lineHeight = 16; addSubview(label) }
        for v in [track, bar] { v.radius = 3; addSubview(v) }
        track.fill = Themed.color(\.muted, 0.6)
        track.setAccessibilityElement(true)
        track.setAccessibilityRole(.progressIndicator)
        track.setAccessibilityLabel("Context window usage")
        note.balanced = true
        reasonText.balanced = true
        button.action = { [weak self] in self?.onCompact?() }
        for v in [note, button, reasonText] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Fills the popup; false when nothing changed.
    func configure(usage: ThreadContextWindowUsage, model name: String?, compactOffered: Bool, disabled: Bool, reason: String?) -> Bool {
        let next = Model(usage: usage, model: name, compactOffered: compactOffered, disabled: disabled, reason: reason)
        guard next != model else { return false }
        model = next
        let tokens = ThreadContextWindowUsage.tokens
        if let maximum = usage.maximum, let percent = usage.percentageLabel {
            figure.text = "\(percent) · \(tokens(usage.used))/\(tokens(maximum))"
        } else {
            figure.text = tokens(usage.used)
        }
        fraction = CGFloat(min(100, max(0, usage.percentage ?? 0)) / 100)
        let showsBar = usage.maximum != nil
        track.isHidden = !showsBar
        bar.isHidden = !showsBar
        bar.fill = (usage.percentage ?? 0) > 90 ? Themed.color(\.destructive) : Themed.color(\.mutedForeground, 0.72)
        track.setAccessibilityValue(NSNumber(value: Int((fraction * 100).rounded())))
        for (l, v) in rows { l.removeFromSuperview(); v.removeFromSuperview() }
        rows = []
        func row(_ name: String, _ value: String) {
            let l = LabelView(name, font: DSFont.ui(11), color: Themed.color(\.contrastSecondaryLabel))
            let v = LabelView(value, font: SB.tabular(11, .medium), color: Themed.color(\.contrastSecondaryLabel))
            for x in [l, v] { x.lineHeight = 16; addSubview(x) }
            rows.append((l, v))
        }
        if let total = usage.total, total > 0 { row("Total processed", tokens(total)) }
        // `formatContextWindowCost` (ContextWindowMeter.logic.ts:139-145).
        if let cost = usage.cost { row("Cost", usage.currency + " " + String(format: abs(cost) > 0 && abs(cost) < 0.01 ? "%.4f" : "%.2f", cost)) }
        note.isHidden = !usage.automatically
        // `formatContextWindowCompactionMessage` (ContextWindowMeter.logic.ts:100-110).
        if let threshold = usage.autoCompactThreshold, threshold > 0, threshold < 9e15 {
            note.text = "Compacts automatically at " + Int(threshold).formatted(.number.locale(Locale(identifier: "en_US"))) + " tokens."
        } else {
            note.text = name.map { "Context for " + $0 + " compacts automatically when needed." } ?? "Context compacts automatically when needed."
        }
        button.isHidden = !compactOffered
        button.isEnabled = !disabled
        reasonText.text = reason ?? ""
        reasonText.isHidden = !compactOffered || !disabled || reason == nil
        frame.size = NSSize(width: Self.width + 2 * Self.inset, height: place(apply: false) + Self.inset)
        invalidateIntrinsicContentSize()
        needsLayout = true
        return true
    }

    override var intrinsicContentSize: NSSize { frame.size }

    override func layout() {
        super.layout()
        _ = place(apply: true)
    }

    /// Lays the rows out top down and returns the bottom edge.
    private func place(apply: Bool) -> CGFloat {
        let x = Self.inset, w = Self.width
        var y = Self.inset
        func put(_ v: NSView, _ frame: NSRect) { if apply { v.frame = frame } }
        let fw = ceil(figure.textWidth)
        put(title, NSRect(x: x, y: y, width: max(0, w - fw - 12), height: 16))
        put(figure, NSRect(x: x + w - fw, y: y, width: fw, height: 16))
        y += 16
        if !track.isHidden {
            y += 8
            put(track, NSRect(x: x, y: y, width: w, height: 6))
            put(bar, NSRect(x: x, y: y, width: (w * fraction).rounded(), height: 6))
            y += 6
        }
        for (l, v) in rows {
            y += 8
            let vw = ceil(v.textWidth)
            put(l, NSRect(x: x, y: y, width: max(0, w - vw - 12), height: 16))
            put(v, NSRect(x: x + w - vw, y: y, width: vw, height: 16))
            y += 16
        }
        // `mt-1` on top of the column's `gap-2` for the note and the button.
        if !note.isHidden {
            y += 12
            let h = note.height(forWidth: w)
            put(note, NSRect(x: x, y: y, width: w, height: h))
            y += h
        }
        if !button.isHidden {
            y += 12
            put(button, NSRect(x: x, y: y, width: w, height: 24))
            y += 24
        }
        if !reasonText.isHidden {
            y += 8
            let h = reasonText.height(forWidth: w)
            put(reasonText, NSRect(x: x, y: y, width: w, height: h))
            y += h
        }
        return y
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointerInside?(true) }
    override func mouseExited(with event: NSEvent) { onPointerInside?(false) }
}
