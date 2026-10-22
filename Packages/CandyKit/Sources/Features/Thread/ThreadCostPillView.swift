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
            superview?.needsLayout = true
        }
    }

    private let decoration = BoxDecorationLayer()
    private let digits = RollingTextView(font: TL.tabular(13, .medium), lineHeight: 18)
    private lazy var tip: TooltipController = {
        let tip = TooltipController.attach(to: self, text: "", placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4), delay: 0.15)
        tip.content = { [weak self] in
            PopoverView(content: ThreadCostDetailsView(self?.breakdown ?? .init()), padding: .none, tooltipStyle: true)
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
        box.radius = 10
        box.fill = state.hovered || state.active ? Themed.color(\.accent) : nil
        decoration.boxStyle = box
        digits.color = state.hovered || state.active ? Themed.color(\.contrastForeground) : Themed.color(\.mutedForeground)
        if state.focusVisible { decoration.boxStyle.shadows = BoxShadow.focusRing(ring: Themed.color(\.ring), offset: Themed.color(\.background)) }
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let w = digits.textWidth
        digits.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - 18) / 2).rounded(), width: w, height: 18)
    }
}

/// The pill's card: tokens and cost per kind, the total, the models priced and what the figure leaves out.
final class ThreadCostDetailsView: DSView {
    static let inset: CGFloat = 12, width: CGFloat = 232
    private var rows: [[LabelView]] = []
    private let note = TextBlockView("", font: DSFont.ui(11), lineHeight: 16, color: Themed.color(\.contrastSecondaryLabel))

    init(_ b: ThreadCostEstimate.Breakdown) {
        super.init(frame: .zero)
        // Sub-cent amounts keep four places, as `formatContextWindowCost` does (ContextWindowMeter.logic.ts:139-145).
        func money(_ usd: Double) -> String { usd > 0 && usd < 0.01 ? String(format: "$%.4f", usd) : ThreadCostEstimate.label(usd) }
        let tokens = ThreadContextWindowUsage.tokens
        func row(_ name: String, _ count: String, _ usd: String, strong: Bool = false) {
            let color = Themed.color(strong ? \.foreground : \.contrastSecondaryLabel)
            let cells = [LabelView(name, font: DSFont.ui(strong ? 12 : 11, weight: strong ? .medium : .regular), color: color),
                         LabelView(count, font: TL.tabular(11), color: Themed.color(\.contrastSecondaryLabel)),
                         LabelView(usd, font: TL.tabular(strong ? 12 : 11, .medium), color: color)]
            for c in cells { c.lineHeight = 16; addSubview(c) }
            rows.append(cells)
        }
        row("API cost estimate", "", ThreadCostEstimate.label(b.usd), strong: true)
        let t = b.tokens
        row("Input", tokens(max(0, t.input - t.cached - t.cacheWrite)), money(b.inputUSD))
        row("Cached input", tokens(t.cached), money(b.cachedUSD))
        if t.cacheWrite > 0 { row("Cache writes", tokens(t.cacheWrite), money(b.cacheWriteUSD)) }
        row("Output", tokens(t.output), money(b.outputUSD))
        note.text = "Priced as \(b.models.joined(separator: ", ")). Subagents' own tokens aren't counted."
        addSubview(note)
        frame.size = NSSize(width: Self.width + 2 * Self.inset, height: place(apply: false) + Self.inset)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }

    override func layout() {
        super.layout()
        _ = place(apply: true)
    }

    /// Name on the left, the cost at the right edge and the token count in a column 64pt before it.
    private func place(apply: Bool) -> CGFloat {
        let x = Self.inset, w = Self.width
        var y = Self.inset
        for (i, cells) in rows.enumerated() {
            if i == 1 { y += 4 }
            let usdW = ceil(cells[2].textWidth), countW = ceil(cells[1].textWidth)
            if apply {
                cells[0].frame = NSRect(x: x, y: y, width: w - 64 - countW - 8, height: 16)
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
