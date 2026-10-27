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
        let provider = projection.providerThreads.first(where: { $0["id"]?.stringValue == projection.thread.activeProviderThreadId })
        if let provider, let usage = provider["contextUsage"], let result = read(usage, live: false, updatedAt: date(provider["updatedAt"])) { return result }
        if latest == nil, provider?["contextUsage"] == nil, let usage = forkSourceUsage(projection),
           let result = read(usage, live: true, updatedAt: date(usage["updatedAt"])) { return result }
        for entry in projection.visibleTurnItems.reversed() {
            let item = entry.item.raw
            if item["type"]?.stringValue == "compaction", let used = item["afterTokenCount"]?.doubleValue, used >= 0 {
                return Self(used: used, total: item["beforeTokenCount"]?.doubleValue, automatically: true,
                            updatedAt: date(item["startedAt"]) ?? date(item["updatedAt"]))
            }
        }
        return nil
    }
    /// `latestProviderTurnTokenUsage` (lib/contextWindow.ts:43-56, cfa76eab67): a fork with no usage of its
    /// own reads the parent's, carried as `sourceTokenUsage` on its native fork transfer.
    static func forkSourceUsage(_ projection: ThreadProjection) -> JSONValue? {
        let thread = projection.thread.raw, from = thread["forkedFrom"]
        guard from?["type"]?.stringValue == "run", let sourceThread = from?["threadId"]?.stringValue else { return nil }
        let me = projection.thread.id.localId, instance = thread["modelSelection"]?["instanceId"]?.stringValue
        return projection.contextTransfers.first { t in
            t["type"]?.stringValue == "fork"
                && t["targetThreadId"]?.stringValue.map { ThreadId($0).localId } == me
                && t["sourceThreadId"]?.stringValue.map { ThreadId($0).localId } == ThreadId(sourceThread).localId
                && t["sourcePoint"]?["runId"] == from?["runId"]
                && t["sourceProviderInstanceId"]?.stringValue == instance
                && (t["status"]?.stringValue == "pending" || t["resolution"]?["strategy"]?.stringValue == "native_fork")
        }?["sourceTokenUsage"]
    }

    public static func tokens(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value < 1_000 { return String(Int(value.rounded())) }
        if value < 10_000 { return decimal(value / 1_000) + "k" }
        // Anything from 999,500 rounds to 1000k, so it belongs to the next unit (contextWindow.ts:174-177).
        if value < 999_500 { return String(Int((value / 1_000).rounded())) + "k" }
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
        // Under Dither the panel places the ring, so it lays out again when the ring comes or goes.
        if (usage == nil) != (oldValue == nil) { superview?.needsLayout = true }
    } }
    /// Runs Compact context. The popup offers the button only while `compactOffered` (ChatComposer.tsx:7673:
    /// the selected provider has a `compact` command).
    public var onCompact: (@MainActor () -> Void)?
    public var compactOffered = false
    private weak var detailsPopup: OpenPopup?
    private var hoverWork: DispatchWorkItem?
    private var pointerInDetails = false
    public var modelDisplayName: String?
    /// The open thread, read only when Redesign's popover opens, to estimate what fills the window.
    public var projection: ThreadProjection?
    /// The thread's history window starts after its first item, so the estimate can't see all of the context.
    public var hasEarlierHistory = false
    private var estimateCache: (key: String, value: ThreadContextEstimate?)?
    /// One estimate per thread revision and report, so the popover's refreshes reuse it.
    // ponytail: runs on the main thread when the popover opens, one pass over the items; move it off the main
    // thread if long threads stall the popover.
    private func estimate(_ usage: ThreadContextWindowUsage) -> ThreadContextEstimate? {
        guard capy else { return nil }
        let p = projection
        let key = "\(p?.thread.id.rawValue ?? "") \(p?.updatedAt.description ?? "") \(p?.visibleTurnItems.count ?? 0) "
            + "\(p?.visibleTurnItems.last?.item.updatedAt.description ?? "") \(usage.used) \(hasEarlierHistory)"
        if let estimateCache, estimateCache.key == key { return estimateCache.value }
        let value = ThreadContextEstimate.estimate(projection, used: usage.used, hasEarlierHistory: hasEarlierHistory)
        estimateCache = (key, value)
        return value
    }
    /// The Compact context button is disabled; `compactDisabledReason` shows under it when set.
    public var compactDisabled = false
    public var compactDisabledReason: String?
    /// `ContextWindowMeterPlaceholder` (ContextWindowMeter.tsx:177-180): with no usage yet, the composer
    /// still holds the meter's 28pt slot so the attach button does not move when it arrives.
    public var reserved = false { didSet { if reserved != oldValue { superview?.needsLayout = true; needsDisplay = true } } }
    /// Dither: Capy's ring (measured in Capy 2026-10-22), a 13pt circle with a 1.5pt stroke in a 28pt pill under the
    /// composer, opened by a click into Capy's Context popover.
    var capy: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    private var ringRadius: CGFloat { capy ? 5.75 : 9.75 * 20 / 24 }
    private var ringWidth: CGFloat { capy ? 1.5 : 2.5 }
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
        action = { [weak self] in
            guard let self else { return }
            if self.capy, self.detailsPopup != nil { self.closeDetails() } else { self.showDetails() }
        }
        arc.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "strokeEnd": NSNull(), "strokeColor": NSNull(), "hidden": NSNull()]
        arc.fillColor = nil
        arc.lineWidth = 2.5
        arc.lineCap = .round
        arc.isHidden = true
        layer?.addSublayer(arc)
    }

    /// The usage arc as a layer, so its `stroke-dashoffset` and `stroke` changes run 500ms `ease-out`
    /// (ContextWindowMeter.tsx:82; Tailwind's `ease-out` is `cubic-bezier(0, 0, .2, 1)`).
    let arc = CAShapeLayer()
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)

    private func updateArc(animated: Bool) {
        let fraction = min(1, max(0, (usage?.percentage ?? 0) / 100))
        let color = (fraction > 0.9 ? Themed.color(\.destructive) : Themed.color(capy ? \.foreground : \.mutedForeground, capy ? 0.8 : 0.72)).cgColor(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, !arc.isHidden, fraction > 0, window != nil, !Motion.reduced {
            Motion.animate(arc, keyPath: "strokeEnd", to: fraction, duration: 0.5, timing: Self.easeOut)
            Motion.animate(arc, keyPath: "strokeColor", to: color, duration: 0.5, timing: Self.easeOut)
        }
        arc.isHidden = fraction <= 0
        arc.lineWidth = ringWidth
        arc.strokeEnd = fraction
        arc.strokeColor = color
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateArc(animated: false)
        needsLayout = true
        needsDisplay = true
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Redesign's pill always holds a ring, so a reserved slot shows the empty track while the usage loads.
        guard let ctx = NSGraphicsContext.current?.cgContext, usage != nil || (capy && reserved) else { return }
        if capy, state.hoverOrPressed || detailsPopup != nil {
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: DitherPill.radius, cornerHeight: DitherPill.radius, transform: nil))
            ctx.setFillColor(Themed.color(\.foreground, 0.07).cgColor(in: self))
            ctx.fillPath()
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = ringRadius
        ctx.setLineWidth(ringWidth)
        ctx.setStrokeColor(Themed.color(\.mutedForeground, capy ? 0.35 : 0.24).cgColor(in: self))
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    public override func layout() {
        super.layout()
        // A full turn from the top, clockwise on screen (y grows downward here); `strokeEnd` is the share used.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(center: center, radius: ringRadius, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
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
        guard usage != nil, detailsPopup == nil, !capy else { return }
        schedule(Self.openDelay) { $0.showDetails() }
    }
    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverWork?.cancel()
        if !capy { scheduleClose() }
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
        needsDisplay = true
        open.content.popupHost?.close(open, returnFocus: false)
    }
    /// The open popup's content, for tests.
    var detailsView: ThreadContextWindowDetailsView? { (detailsPopup?.content as? PopoverView)?.content as? ThreadContextWindowDetailsView }

    /// Shows what changed in an open popup: the button turns disabled with its reason once a compact
    /// starts, as T3's popover re-renders while it stays open.
    private func refreshDetails() {
        guard let open = detailsPopup, let usage, let content = detailsView else { return }
        guard content.configure(usage: usage, capy: capy, estimate: estimate(usage), model: modelDisplayName, compactOffered: compactOffered,
                                disabled: compactDisabled, reason: compactDisabledReason) else { return }
        open.content.invalidateIntrinsicContentSize()
        open.content.popupHost?.reposition(open)
    }

    func showDetails() {
        hoverWork?.cancel()
        guard detailsPopup == nil, let usage, let host = popupHost else { return }
        let content = ThreadContextWindowDetailsView()
        let capy = self.capy
        _ = content.configure(usage: usage, capy: capy, estimate: estimate(usage), model: modelDisplayName, compactOffered: compactOffered,
                              disabled: compactDisabled, reason: compactDisabledReason)
        content.onPointerInside = { [weak self] inside in
            guard let self, !self.capy else { return }
            self.pointerInDetails = inside
            if inside { self.hoverWork?.cancel() } else { self.scheduleClose() }
        }
        content.onCompact = { [weak self] in self?.onCompact?() }
        // Capy's popover opens on a click, sits 6pt above the ring with its right edge on the ring's, and closes on
        // a click outside.
        let popover = PopoverView(content: content, padding: .none, width: capy ? .auto : .sm, tooltipStyle: !capy)
        detailsPopup = host.open(popover, trigger: self, placement: PopupPlacement(side: .top, align: .end, sideOffset: capy ? 6 : 4),
                                 motion: .popover, pressesTrigger: capy, returnsFocus: false, passive: !capy)
        detailsPopup?.onClose = { [weak self] in self?.detailsPopup = nil; self?.pointerInDetails = false; self?.needsDisplay = true }
        needsDisplay = true
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
    /// Dither: Capy's Context popover (measured in Capy 2026-10-22), 286 wide: "Context" with "used / max used (n%)"
    /// at the right, a 5pt bar split by category, a legend row per category (7pt dot, name, count at the right) and a
    /// bordered "Compact at threshold / max" box. Capy splits by system prompt, tools and conversation; T3 reports
    /// only the total, so the categories are `ThreadContextEstimate`'s, with a muted line saying so. Without a
    /// threshold the box reads "Max", and Compact context sits under it as a quiet button.
    private var capy = false
    private var segments: [(view: FillView, share: CGFloat)] = []
    private var dots: [FillView] = []
    /// Capy's legend colors, sampled from its popover, in `ThreadContextEstimate.categories` order: gray, blue, teal,
    /// violet, pink.
    static let partColors: [NSColor] = [NSColor(srgbRed: 0.53, green: 0.53, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.18, green: 0.51, blue: 0.96, alpha: 1),
                                        NSColor(srgbRed: 0.29, green: 0.62, blue: 0.56, alpha: 1), NSColor(srgbRed: 0.55, green: 0.40, blue: 0.96, alpha: 1),
                                        NSColor(srgbRed: 0.87, green: 0.33, blue: 0.56, alpha: 1)]
    static func legend(_ estimate: ThreadContextEstimate) -> [(name: String, value: Double, color: NSColor)] {
        zip(estimate.categories, partColors).map { ($0.name, $0.value, $1) }.filter { $0.value >= 0.5 }
    }
    private let estimateNote = TextBlockView("Estimated from this thread; T3 reports only the total.", font: DSFont.ui(12), lineHeight: 16,
                                             color: Themed.color(\.contrastMutedForeground))
    static let capyWidth: CGFloat = 286 - 2 - 2 * 12
    private let compactBox = DSView()
    private let compactLabel = LabelView("Compact at", font: DSFont.ui(13), color: Themed.color(\.contrastForeground))
    private let compactValue = LabelView("", font: SB.tabular(13, .medium), color: Themed.color(\.contrastForeground))
    private let compactMaximum = LabelView("", font: SB.tabular(13), color: Themed.color(\.contrastMutedForeground))
    private var contentWidth: CGFloat { capy ? Self.capyWidth : Self.width }

    private struct Model: Equatable {
        var usage: ThreadContextWindowUsage, capy: Bool, estimate: ThreadContextEstimate?, model: String?, compactOffered: Bool, disabled: Bool, reason: String?
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
        estimateNote.isHidden = true
        for v in [note, estimateNote, button, reasonText] as [NSView] { addSubview(v) }
        compactBox.layer?.borderWidth = 0.5
        compactBox.layer?.cornerRadius = DitherChrome.controlRadius
        compactBox.isHidden = true
        addSubview(compactBox)
        for l in [compactLabel, compactValue, compactMaximum] { l.lineHeight = 18; l.isHidden = true; addSubview(l) }
    }

    override func updateLayer() {
        super.updateLayer()
        compactBox.layer?.borderColor = Themed.color(\.contrastForeground, 0.1).cgColor(in: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Fills the popup; false when nothing changed.
    func configure(usage: ThreadContextWindowUsage, capy: Bool = false, estimate: ThreadContextEstimate? = nil, model name: String?,
                   compactOffered: Bool, disabled: Bool, reason: String?) -> Bool {
        let next = Model(usage: usage, capy: capy, estimate: estimate, model: name, compactOffered: compactOffered, disabled: disabled, reason: reason)
        guard next != model else { return false }
        model = next
        self.capy = capy
        // Capy writes token counts with capital units and a decimal under 100K: 37.3K, 400K, 1.1M.
        func tokens(_ value: Double) -> String {
            guard capy else { return ThreadContextWindowUsage.tokens(value) }
            if value >= 1_000, value < 99_950 { return String(format: "%.1f", value / 1_000).replacingOccurrences(of: ".0", with: "") + "K" }
            return ThreadContextWindowUsage.tokens(value).uppercased()
        }
        title.text = capy ? "Context" : "Context Window"
        title.font = capy ? DSFont.ui(13, weight: .medium) : DSFont.ui(12, weight: .medium)
        title.color = Themed.color(capy ? \.contrastForeground : \.mutedForeground)
        figure.font = capy ? SB.tabular(12) : SB.tabular(11)
        figure.color = Themed.color(capy ? \.contrastMutedForeground : \.contrastSecondaryLabel)
        for l in [title, figure] { l.lineHeight = capy ? 18 : 16 }
        if capy {
            figure.text = usage.maximum.map { "\(tokens(usage.used)) / \(tokens($0)) used" + (usage.percentageLabel.map { " (\($0))" } ?? "") }
                ?? "\(tokens(usage.used)) used"
        } else if let maximum = usage.maximum, let percent = usage.percentageLabel {
            figure.text = "\(percent) · \(tokens(usage.used))/\(tokens(maximum))"
        } else {
            figure.text = tokens(usage.used)
        }
        track.fill = capy ? Themed.color(\.contrastForeground, 0.1) : Themed.color(\.muted, 0.6)
        fraction = CGFloat(min(100, max(0, usage.percentage ?? 0)) / 100)
        let showsBar = usage.maximum != nil
        track.isHidden = !showsBar
        bar.isHidden = !showsBar
        bar.fill = (usage.percentage ?? 0) > 90 ? Themed.color(\.destructive) : capy ? Themed.color(\.contrastForeground, 0.72) : Themed.color(\.mutedForeground, 0.72)
        track.setAccessibilityValue(NSNumber(value: Int((fraction * 100).rounded())))
        for (l, v) in rows { l.removeFromSuperview(); v.removeFromSuperview() }
        rows = []
        for v in segments.map(\.view) + dots { v.removeFromSuperview() }
        segments = []; dots = []
        func row(_ name: String, _ value: String) {
            let l = capy ? LabelView(name, font: DSFont.ui(13), color: Themed.color(\.contrastForeground))
                : LabelView(name, font: DSFont.ui(11), color: Themed.color(\.contrastSecondaryLabel))
            let v = capy ? LabelView(value, font: SB.tabular(13), color: Themed.color(\.contrastMutedForeground))
                : LabelView(value, font: SB.tabular(11, .medium), color: Themed.color(\.contrastSecondaryLabel))
            for x in [l, v] { x.lineHeight = capy ? 18 : 16; addSubview(x) }
            rows.append((l, v))
        }
        if capy {
            // One segment and one legend row per category, each segment its share of the window.
            let legend = estimate.map(Self.legend) ?? []
            let maximum = usage.maximum ?? 0
            for part in legend {
                row(part.name, "~" + tokens(part.value))
                let dot = FillView(), segment = FillView()
                dot.radius = 3.5
                for v in [dot, segment] { v.fill = part.color; v.setAccessibilityElement(false) }
                addSubview(dot)
                track.addSubview(segment)
                dots.append(dot); segments.append((segment, maximum > 0 ? CGFloat(min(1, part.value / maximum)) : 0))
            }
            // Without a thread to estimate from, the single bar.
            bar.isHidden = !showsBar || !legend.isEmpty
            track.clipsToBounds = true
        }
        estimateNote.isHidden = !capy || dots.isEmpty
        estimateNote.text = estimate?.includesEarlier == true ? "Estimated from the loaded messages; T3 reports only the total."
            : "Estimated from this thread; T3 reports only the total."
        if !capy, let total = usage.total, total > 0 { row("Total processed", tokens(total)) }
        // `formatContextWindowCost` (ContextWindowMeter.logic.ts:139-145).
        if !capy, let cost = usage.cost { row("Cost", usage.currency + " " + String(format: abs(cost) > 0 && abs(cost) < 0.01 ? "%.4f" : "%.2f", cost)) }
        // Capy's "Compact at" box: the threshold, then the window it sits in.
        let threshold = usage.autoCompactThreshold.flatMap { $0 > 0 && $0 < 9e15 ? $0 : nil }
        let boxed = capy && (threshold != nil || usage.maximum != nil)
        for v in [compactBox, compactLabel, compactValue, compactMaximum] as [NSView] { v.isHidden = !boxed }
        compactBox.layer?.borderColor = Themed.color(\.contrastForeground, 0.1).cgColor(in: self)
        if boxed {
            compactLabel.text = threshold != nil ? "Compact at" : "Max"
            compactValue.text = threshold.map(tokens) ?? ""
            compactMaximum.text = usage.maximum.map { (threshold != nil ? " / " : "") + tokens($0) } ?? ""
            compactMaximum.color = Themed.color(threshold != nil ? \.contrastMutedForeground : \.contrastForeground)
        }
        note.font = capy ? DSFont.ui(12) : DSFont.ui(11, weight: .medium)
        note.color = Themed.color(capy ? \.contrastMutedForeground : \.contrastSecondaryLabel)
        note.isHidden = !usage.automatically || capy
        // `formatContextWindowCompactionMessage` (ContextWindowMeter.logic.ts:100-110).
        if let threshold = usage.autoCompactThreshold, threshold > 0, threshold < 9e15 {
            note.text = "Compacts automatically at about " + Int(threshold).formatted(.number.locale(Locale(identifier: "en_US"))) + " tokens."
        } else {
            note.text = name.map { "Context for " + $0 + " compacts automatically when needed." } ?? "Context compacts automatically when needed."
        }
        button.isHidden = !compactOffered
        button.variant = capy ? .ghostMuted : .outline
        button.isEnabled = !disabled
        reasonText.text = reason ?? ""
        reasonText.isHidden = !compactOffered || !disabled || reason == nil
        needsDisplay = true
        frame.size = NSSize(width: contentWidth + 2 * Self.inset, height: place(apply: false) + Self.inset)
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
        let x = Self.inset, w = contentWidth
        var y = Self.inset
        func put(_ v: NSView, _ frame: NSRect) { if apply { v.frame = frame } }
        let fw = ceil(figure.textWidth), line: CGFloat = capy ? 18 : 16
        put(title, NSRect(x: x, y: y, width: max(0, w - fw - 12), height: line))
        put(figure, NSRect(x: x + w - fw, y: y, width: fw, height: line))
        y += line
        if !track.isHidden {
            // Capy: the 5pt bar 10 under the title, its segments laid end to end from the left.
            let h: CGFloat = capy ? 5 : 6
            y += capy ? 10 : 8
            put(track, NSRect(x: x, y: y, width: w, height: h))
            put(bar, NSRect(x: x, y: y, width: (w * fraction).rounded(), height: h))
            var sx: CGFloat = 0
            for s in segments {
                let sw = (s.share * w).rounded()
                if apply { s.view.frame = NSRect(x: sx, y: 0, width: sw, height: h) }
                sx += sw
            }
            y += h
        }
        if capy, !rows.isEmpty { y += 8 }
        for (i, (l, v)) in rows.enumerated() {
            // Capy: 21.5pt rows, a 7pt dot, the name 16 in.
            y += capy ? (i == 0 ? 0 : 3.5) : 8
            let vw = ceil(v.textWidth), lead: CGFloat = i < dots.count ? 16 : 0
            if i < dots.count { put(dots[i], NSRect(x: x, y: y + (line - 7) / 2, width: 7, height: 7)) }
            put(l, NSRect(x: x + lead, y: y, width: max(0, w - vw - 12 - lead), height: line))
            put(v, NSRect(x: x + w - vw, y: y, width: vw, height: line))
            y += line
        }
        if !estimateNote.isHidden {
            y += 6
            let h = estimateNote.height(forWidth: w)
            put(estimateNote, NSRect(x: x, y: y, width: w, height: h))
            y += h
        }
        if !compactBox.isHidden {
            y += 12
            put(compactBox, NSRect(x: x, y: y, width: w, height: 28))
            let mw = ceil(compactMaximum.textWidth), vw = ceil(compactValue.textWidth)
            put(compactMaximum, NSRect(x: x + w - 9 - mw, y: y + 5, width: mw, height: 18))
            put(compactValue, NSRect(x: x + w - 9 - mw - vw, y: y + 5, width: vw, height: 18))
            put(compactLabel, NSRect(x: x + 9, y: y + 5, width: max(0, w - 30 - mw - vw), height: 18))
            y += 28
        }
        // `mt-1` on top of the column's `gap-2` for the note and the button.
        if !note.isHidden {
            y += 12
            let h = note.height(forWidth: w)
            put(note, NSRect(x: x, y: y, width: w, height: h))
            y += h
        }
        if !button.isHidden {
            y += capy ? 6 : 12
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
