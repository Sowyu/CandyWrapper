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
    /// The latest request's prompt, the part of it read from the prompt cache, and its reply, as the provider
    /// reported them on a live report (`OrchestrationV2ProviderTurnTokenUsage`, orchestrationV2.ts:232-243).
    public var inputTokens: Double? = nil
    public var cachedInputTokens: Double? = nil
    public var outputTokens: Double? = nil
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
                        updatedAt: updatedAt, promptCacheTtlMs: live ? json["promptCacheTtlMs"]?.doubleValue : nil,
                        // `contextUsage` counts these over the whole thread, so only a live report's describe the window.
                        inputTokens: live ? json["inputTokens"]?.doubleValue : nil,
                        cachedInputTokens: live ? json["cachedInputTokens"]?.doubleValue : nil,
                        outputTokens: live ? json["outputTokens"]?.doubleValue : nil)
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

    /// What fills the window, split only by the provider's own counts: Claude and Codex report `usedTokens` as
    /// the latest request's input plus its output (ClaudeAdapterV2.ts:322, CodexAdapterV2.ts:220), cache reads
    /// being part of the input. Nil unless those counts add up to `used` exactly; nothing here is estimated.
    public var breakdown: [(name: String, value: Double)]? {
        guard let input = inputTokens, let output = outputTokens, input >= 0, output >= 0, input + output == used else { return nil }
        let cached = cachedInputTokens ?? 0
        guard cached >= 0, cached <= input else { return nil }
        return [("Prompt read from cache", cached), ("Rest of the prompt", input - cached), ("Latest reply", output)]
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

    /// How full the window is, in the fixed status colors (Redesign's ring, never the accent).
    public enum Level: Equatable, Sendable { case neutral, warning, danger }

    /// Danger at or past "Compact at" or from 95%; warning in the 10 points before "Compact at", or from 80% when the
    /// provider reports no threshold.
    public static func level(percentage p: Double, compactAt: Double?) -> Level {
        if p >= 95 || compactAt.map({ p >= $0 }) == true { return .danger }
        return p >= (compactAt.map { $0 - 10 } ?? 80) ? .warning : .neutral
    }

    /// "Compact at" as a share of the window, when the provider reported both.
    public var compactAtPercentage: Double? {
        guard let t = autoCompactThreshold, t > 0, t < 9e15, let m = maximum, m > 0 else { return nil }
        return t / m * 100
    }

    /// Judged on the figure the pill shows, so "95%" is never drawn in the color of 94%.
    public var level: Level {
        percentage.map { Self.level(percentage: $0 < 10 ? $0 : $0.rounded(), compactAt: compactAtPercentage) } ?? .neutral
    }

    /// The pill's tooltip and accessibility value: "Context: 949K of 1M used (95%)".
    public var redesignSummary: String {
        let used = Self.tokens(used).uppercased()
        guard let maximum, let label = percentageLabel else { return "Context: \(used) used" }
        return "Context: \(used) of \(Self.tokens(maximum).uppercased()) used (\(label))"
    }
}

/// ContextWindowMeter.tsx:42-211. No timer or idle animation; the stream changes the ring.
public final class ThreadContextWindowMeterView: ControlView {
    public var usage: ThreadContextWindowUsage? { didSet {
        guard usage != oldValue else { return }
        needsDisplay = true
        updateArc(animated: oldValue != nil)
        setAccessibilityLabel(summary)
        setAccessibilityValue(capy ? usage?.redesignSummary : usage?.percentage.map { NSNumber(value: $0) })
        setAccessibilityElement(usage != nil)
        syncFigure()
        if usage == nil, !(capy && reserved) { closeDetails() } else { refreshDetails() }
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
    /// The Compact context button is disabled; `compactDisabledReason` shows under it when set.
    public var compactDisabled = false
    public var compactDisabledReason: String?
    /// `ContextWindowMeterPlaceholder` (ContextWindowMeter.tsx:177-180): with no usage yet, the composer
    /// still holds the meter's 28pt slot so the attach button does not move when it arrives.
    public var reserved = false { didSet {
        guard reserved != oldValue else { return }
        superview?.needsLayout = true; needsDisplay = true
        if usage == nil { closeDetails() }
    } }
    /// Dither: Capy's ring (measured in Capy 2026-10-22), a 13pt circle with a 1.5pt stroke in a 28pt pill under the
    /// composer, opened by a click into Capy's Context popover.
    var capy: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    /// Redesign: a 12pt ring with a 2pt stroke where the Stash pill has its icon, then the share used as text (the user,
    /// 2026-11-21: "this is borderline unreadable", about the bare 13pt ring at 1.5pt).
    private var ringRadius: CGFloat { capy ? 5 : 9.75 * 20 / 24 }
    private var ringWidth: CGFloat { capy ? 2 : 2.5 }
    private var ringCenter: CGPoint { capy ? CGPoint(x: Self.figureX / 2, y: bounds.midY) : CGPoint(x: bounds.midX, y: bounds.midY) }
    /// Where the figure starts in Redesign's pill, and the pill's right padding: the Stash pill's icon column and title.
    static let figureX: CGFloat = 32, figureTrail: CGFloat = 8
    let figure = LabelView("", font: TL.tabular(12))
    private lazy var tip = TooltipController.attach(to: self, text: "")
    /// Redesign's pill width: the ring and the figure, or the square when there is no figure.
    public var redesignWidth: CGFloat {
        figure.text.isEmpty ? DitherPill.height : Self.figureX + ceil(figure.textWidth) + Self.figureTrail
    }
    public override var wantsUpdateLayer: Bool { false }
    public override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

    private func syncFigure() {
        let text = capy ? (usage?.percentageLabel ?? usage.map { ThreadContextWindowUsage.tokens($0.used).uppercased() } ?? "") : ""
        figure.isHidden = text.isEmpty
        figure.color = Themed.color(figureColor)
        tip.text = capy ? usage?.redesignSummary ?? "" : ""
        guard figure.text != text else { return }
        let widthChanged = figure.text.count != text.count || figure.text.isEmpty != text.isEmpty
        figure.text = text
        needsLayout = true
        if widthChanged { superview?.needsLayout = true }
    }

    private var figureColor: KeyPath<Palette, TokenColor> {
        switch usage?.level ?? .neutral {
        case .neutral: \.foreground
        case .warning: \.warningForeground
        case .danger: \.destructiveForeground
        }
    }
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
        figure.lineHeight = 16
        figure.isHidden = true
        addSubview(figure)
    }

    /// The usage arc as a layer, so its `stroke-dashoffset` and `stroke` changes run 500ms `ease-out`
    /// (ContextWindowMeter.tsx:82; Tailwind's `ease-out` is `cubic-bezier(0, 0, .2, 1)`).
    let arc = CAShapeLayer()
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)

    private func updateArc(animated: Bool) {
        let fraction = min(1, max(0, (usage?.percentage ?? 0) / 100))
        let color: CGColor
        if capy {
            // Redesign: the fill at full strength over a hairline track, in the status colors as the window fills.
            let level = usage?.level ?? .neutral
            color = Themed.color(level == .danger ? \.destructive : level == .warning ? \.warning : \.foreground).cgColor(in: self)
        } else {
            color = (fraction > 0.9 ? Themed.color(\.destructive) : Themed.color(\.mutedForeground, 0.72)).cgColor(in: self)
        }
        // Redesign eases the change briefly on its own curve; T3 takes 500ms `ease-out`.
        let duration = capy ? RedesignTokens.Motion.appear : 0.5, timing = capy ? RedesignTokens.Motion.curve : Self.easeOut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, !arc.isHidden, fraction > 0, window != nil, !Motion.reduced {
            Motion.animate(arc, keyPath: "strokeEnd", to: fraction, duration: duration, timing: timing)
            Motion.animate(arc, keyPath: "strokeColor", to: color, duration: duration, timing: timing)
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
        syncFigure()
        needsLayout = true
        needsDisplay = true
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Redesign shows nothing until the provider reports usage: an empty ring said nothing.
        guard let ctx = NSGraphicsContext.current?.cgContext, usage != nil else { return }
        if capy, state.hoverOrPressed || detailsPopup != nil {
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: DitherPill.radius, cornerHeight: DitherPill.radius, transform: nil))
            ctx.setFillColor(Themed.color(\.foreground, 0.07).cgColor(in: self))
            ctx.fillPath()
        }
        let center = ringCenter
        let radius = ringRadius
        ctx.setLineWidth(ringWidth)
        ctx.setStrokeColor(capy ? RedesignTokens.Surface.rim(dark: effectiveAppearance.isDark).cgColor
                                : Themed.color(\.mutedForeground, 0.24).cgColor(in: self))
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    public override func layout() {
        super.layout()
        // A full turn from the top, clockwise on screen (y grows downward here); `strokeEnd` is the share used.
        let center = ringCenter
        figure.frame = NSRect(x: Self.figureX, y: ((bounds.height - 16) / 2).rounded(), width: ceil(figure.textWidth) + 1, height: 16)
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
        guard let open = detailsPopup, let content = detailsView else { return }
        guard content.configure(usage: usage, capy: capy, model: modelDisplayName, compactOffered: compactOffered,
                                disabled: compactDisabled, reason: compactDisabledReason) else { return }
        open.content.invalidateIntrinsicContentSize()
        open.content.popupHost?.reposition(open)
    }

    func showDetails() {
        hoverWork?.cancel()
        // Redesign's ring shows before any report, so a click on it says there is none yet.
        guard detailsPopup == nil, usage != nil || (capy && reserved), let host = popupHost else { return }
        let content = ThreadContextWindowDetailsView()
        let capy = self.capy
        _ = content.configure(usage: usage, capy: capy, model: modelDisplayName, compactOffered: compactOffered,
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
    /// bordered "Compact at threshold / max" box. Capy splits by system prompt, tools and conversation; T3 has no such
    /// split, so the legend shows only `ThreadContextWindowUsage.breakdown`, the provider's own counts for its latest
    /// request, and no legend when it has none. Before any report it says so. Without a threshold the box reads
    /// "Max", and Compact context sits under it as a quiet button.
    private var capy = false
    private var segments: [(view: FillView, share: CGFloat)] = []
    private var dots: [FillView] = []
    /// The legend colors in `ThreadContextWindowUsage.breakdown` order: three steps of the text color. Capy's popover
    /// used gray, blue and teal; Redesign keeps hue for its one accent and the status colors.
    static let partColors: [NSColor] = [Themed.color(\.foreground, 0.85), Themed.color(\.foreground, 0.55), Themed.color(\.foreground, 0.3)]
    /// The legend rows: reported counts only, empty when the provider gave no split.
    static func legend(_ usage: ThreadContextWindowUsage?) -> [(name: String, value: Double, color: NSColor)] {
        zip(usage?.breakdown ?? [], partColors).map { ($0.name, $0.value, $1) }.filter { $0.value > 0 }
    }
    static let breakdownNote = "As the provider reported its latest request."
    static let unreportedNote = "No usage reported for this thread yet."
    private let sourceNote = TextBlockView(breakdownNote, font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.contrastMutedForeground))
    static let capyWidth: CGFloat = 286 - 2 - 2 * 12
    private let compactBox = DSView()
    private let compactLabel = LabelView("Compact at", font: DSFont.ui(13), color: Themed.color(\.contrastForeground))
    private let compactValue = LabelView("", font: SB.tabular(13, .medium), color: Themed.color(\.contrastForeground))
    private let compactMaximum = LabelView("", font: SB.tabular(13), color: Themed.color(\.contrastMutedForeground))
    private var contentWidth: CGFloat { capy ? Self.capyWidth : Self.width }

    private struct Model: Equatable {
        var usage: ThreadContextWindowUsage?, capy: Bool, model: String?, compactOffered: Bool, disabled: Bool, reason: String?
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
        sourceNote.isHidden = true
        for v in [note, sourceNote, button, reasonText] as [NSView] { addSubview(v) }
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
    /// `usage` is nil only for Redesign's ring before the first report.
    func configure(usage reported: ThreadContextWindowUsage?, capy: Bool = false, model name: String?,
                   compactOffered: Bool, disabled: Bool, reason: String?) -> Bool {
        let next = Model(usage: reported, capy: capy, model: name, compactOffered: compactOffered, disabled: disabled, reason: reason)
        guard next != model else { return false }
        model = next
        self.capy = capy
        let usage = reported ?? ThreadContextWindowUsage(used: 0, automatically: false)
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
        if reported == nil {
            figure.text = ""
        } else if capy {
            figure.text = usage.maximum.map { "\(tokens(usage.used)) / \(tokens($0)) used" + (usage.percentageLabel.map { " (\($0))" } ?? "") }
                ?? "\(tokens(usage.used)) used"
        } else if let maximum = usage.maximum, let percent = usage.percentageLabel {
            figure.text = "\(percent) · \(tokens(usage.used))/\(tokens(maximum))"
        } else {
            figure.text = tokens(usage.used)
        }
        track.fill = capy ? Themed.color(\.contrastForeground, 0.1) : Themed.color(\.muted, 0.6)
        fraction = CGFloat(min(100, max(0, usage.percentage ?? 0)) / 100)
        let showsBar = reported != nil && usage.maximum != nil
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
            let legend = Self.legend(reported)
            let maximum = usage.maximum ?? 0
            for part in legend {
                row(part.name, tokens(part.value))
                let dot = FillView(), segment = FillView()
                dot.radius = RedesignTokens.Radius.capsule(7)
                for v in [dot, segment] { v.fill = part.color; v.setAccessibilityElement(false) }
                addSubview(dot)
                track.addSubview(segment)
                dots.append(dot); segments.append((segment, maximum > 0 ? CGFloat(min(1, part.value / maximum)) : 0))
            }
            // Without a reported split, the single bar.
            bar.isHidden = !showsBar || !legend.isEmpty
            track.clipsToBounds = true
        }
        sourceNote.isHidden = !capy || (dots.isEmpty && reported != nil)
        sourceNote.text = reported == nil ? Self.unreportedNote : Self.breakdownNote
        if !capy, let total = usage.total, total > 0 { row("Total processed", tokens(total)) }
        // `formatContextWindowCost` (ContextWindowMeter.logic.ts:139-145).
        if !capy, let cost = usage.cost { row("Cost", usage.currency + " " + String(format: abs(cost) > 0 && abs(cost) < 0.01 ? "%.4f" : "%.2f", cost)) }
        // Capy's "Compact at" box: the threshold, then the window it sits in.
        let threshold = usage.autoCompactThreshold.flatMap { $0 > 0 && $0 < 9e15 ? $0 : nil }
        let boxed = capy && reported != nil && (threshold != nil || usage.maximum != nil)
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
        note.isHidden = reported == nil || !usage.automatically || capy
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
        if !sourceNote.isHidden {
            y += 6
            let h = sourceNote.height(forWidth: w)
            put(sourceNote, NSRect(x: x, y: y, width: w, height: h))
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
