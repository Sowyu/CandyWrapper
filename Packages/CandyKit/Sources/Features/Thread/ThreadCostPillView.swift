import AppKit
import DesignSystem

/// Redesign's thread cost, after Capy's tab bar figure: a quiet pill left of the header toggles, as tall and
/// round as they are, with their ghost hover fill. Hover or a click shows the breakdown. The digits roll only
/// when the figure changes.
public final class ThreadCostPillView: ControlView {
    /// Nil hides the pill: no usage yet, or a turn on a model without a price.
    public var breakdown: ThreadCostEstimate.Breakdown? {
        didSet {
            guard breakdown != oldValue else { return }
            let text = breakdown.map { ThreadCostEstimate.label($0.usd) } ?? ""
            // A thread switch sets the figure without rolling; a change on the same thread rolls.
            digits.set(prefix: "", value: text, animated: oldValue != nil && breakdown != nil)
            setAccessibilityValue(text)
            invalidateIntrinsicContentSize()
            needsLayout = true
            digits.needsLayout = true
            // In Redesign's pill the tab strip has to re-measure it too, or a thread switch leaves a stale gap.
            if let pill = superview as? DitherHeaderPillView { pill.resized() } else { superview?.needsLayout = true }
        }
    }

    /// The card is opening: the controller reads subagent usage it hasn't read yet.
    public var onOpen: (() -> Void)?

    private let decoration = BoxDecorationLayer()
    private let digits = RollingTextView(font: TL.tabular(13, .medium), lineHeight: 18)
    private lazy var tip: TooltipController = {
        let tip = TooltipController.attach(to: self, text: "", placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4), delay: 0.15)
        tip.content = { [weak self] in
            self?.onOpen?()
            return PopoverView(content: ThreadCostDetailsView(self?.breakdown ?? .init()), padding: .none, tooltipStyle: true)
        }
        return tip
    }()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        scalesWhenPressed = false
        addSubview(digits)
        _ = tip
        action = { [weak self] in self?.tip.show(instant: true) }
        setAccessibilityRole(.button)
        setAccessibilityLabel("Estimated cost at API prices")
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds an open card after new subagent usage arrives.
    public func refreshCard() {
        guard tip.isShown else { return }
        tip.hide()
        tip.show(instant: true)
    }

    /// `ToggleView` ghost `.sm`: 28 tall, 10 round; 8 either side of the digits.
    public override var intrinsicContentSize: NSSize { NSSize(width: max(28, digits.textWidth + 16), height: 28) }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        // ToggleView's radius: `.sm` 10 at 28 tall, `.xs` 8 at 24 (Redesign's pill).
        box.radius = bounds.height < 28 ? 8 : 10
        box.fill = state.hovered || state.active ? Themed.color(\.accent) : nil
        decoration.boxStyle = box
        digits.color = state.hovered || state.active ? Themed.color(\.contrastForeground) : Themed.color(\.mutedForeground)
        if state.focusVisible { decoration.boxStyle.shadows = BoxShadow.focusRing(ring: Themed.color(\.ring), offset: Themed.color(\.background)) }
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let w = digits.textWidth
        restyle()
        digits.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - 18) / 2).rounded(), width: w, height: 18)
    }
}

/// The pill's card: tokens and cost per kind, the total, the models priced and what the figure leaves out.
final class ThreadCostDetailsView: DSView {
    static let inset: CGFloat = 12, width: CGFloat = 232
    private var rows: [(cells: [LabelView], indent: CGFloat)] = []
    private let note = TextBlockView("", font: DSFont.ui(11), lineHeight: 16, color: Themed.color(\.contrastSecondaryLabel))

    init(_ b: ThreadCostEstimate.Breakdown) {
        super.init(frame: .zero)
        // Sub-cent amounts keep four places, as `formatContextWindowCost` does (ContextWindowMeter.logic.ts:139-145).
        func money(_ usd: Double) -> String { usd > 0 && usd < 0.01 ? String(format: "$%.4f", usd) : ThreadCostEstimate.label(usd) }
        let tokens = ThreadContextWindowUsage.tokens
        func row(_ name: String, _ count: String, _ usd: String, strong: Bool = false, indent: CGFloat = 0) {
            let color = Themed.color(strong ? \.foreground : \.contrastSecondaryLabel)
            let cells = [LabelView(name, font: DSFont.ui(strong ? 12 : 11, weight: strong ? .medium : .regular), color: color),
                         LabelView(count, font: TL.tabular(11), color: Themed.color(\.contrastSecondaryLabel)),
                         LabelView(usd, font: TL.tabular(strong ? 12 : 11, .medium), color: color)]
            for c in cells { c.lineHeight = 16; addSubview(c) }
            rows.append((cells, indent))
        }
        row("API cost estimate", "", ThreadCostEstimate.label(b.usd), strong: true)
        let t = b.tokens
        row("Input", tokens(max(0, t.input - t.cached - t.cacheWrite)), money(b.inputUSD))
        row("Cached input", tokens(t.cached), money(b.cachedUSD))
        if t.cacheWrite > 0 { row("Cache writes", tokens(t.cacheWrite), money(b.cacheWriteUSD)) }
        row("Output", tokens(t.output), money(b.outputUSD))
        let subs = b.subagents
        if !subs.isEmpty {
            let all = subs.reduce(0) { $0 + $1.tokens.input + $1.tokens.output }
            row("Subagents (\(subs.count))", tokens(all), money(b.subagentsUSD))
            // ponytail: a list up to five, the summed row alone past that; a scrolling list if threads run more
            if subs.count <= 5 {
                for s in subs { row(s.title, Self.shortModel(s.models.first ?? ""), money(s.usd), indent: 10) }
            }
        }
        note.text = Self.note(b)
        addSubview(note)
        frame.size = NSSize(width: Self.width + 2 * Self.inset, height: place(apply: false) + Self.inset)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// What the figure counts and what it leaves out.
    static func note(_ b: ThreadCostEstimate.Breakdown) -> String {
        var text = b.models.isEmpty ? "" : "Priced as \(b.models.joined(separator: ", ")). "
        if !b.subagents.isEmpty { text += "Includes subagents' own tokens, each at its own model's price. " }
        func subagents(_ n: Int) -> String { n == 1 ? "1 subagent" : "\(n) subagents" }
        if b.subagentsUnpriced > 0 {
            text += "\(subagents(b.subagentsUnpriced)) left out: no price for \(b.unpricedModels.joined(separator: ", ")). "
        }
        if b.subagentsUnread > 0 { text += "\(subagents(b.subagentsUnread)) left out: usage couldn't be read." }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "haiku-5-5" for "claude-haiku-5-5"; other providers keep their names.
    static func shortModel(_ model: String) -> String { model.hasPrefix("claude-") ? String(model.dropFirst(7)) : model }

    override var intrinsicContentSize: NSSize { frame.size }

    override func layout() {
        super.layout()
        _ = place(apply: true)
    }

    /// Name on the left, the cost at the right edge and the token count in a column 64pt before it.
    private func place(apply: Bool) -> CGFloat {
        let x = Self.inset, w = Self.width
        var y = Self.inset
        for (i, (cells, indent)) in rows.enumerated() {
            if i == 1 { y += 4 }
            let usdW = ceil(cells[2].textWidth), countW = ceil(cells[1].textWidth)
            if apply {
                cells[0].frame = NSRect(x: x + indent, y: y, width: w - 64 - countW - 8 - indent, height: 16)
                cells[1].frame = NSRect(x: x + w - 64 - countW, y: y, width: countW, height: 16)
                cells[2].frame = NSRect(x: x + w - usdW, y: y, width: usdW, height: 16)
            }
            y += i == 0 ? 16 : 20
        }
        y += 6
        let h = note.height(forWidth: w)
        if apply { note.frame = NSRect(x: x, y: y, width: w, height: h) }
        return y + h
    }
}
