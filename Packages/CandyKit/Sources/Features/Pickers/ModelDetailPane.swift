import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What Redesign's detail pane shows for one model (the user's layout 2, 2026-11-21): the name and provider,
/// models.dev's one line, the price per 1M tokens as the mockup has it, and the facts that differ between models.
struct ModelDetailContent: Equatable {
    var key: String
    var name: String
    var provider: String
    var driver: String
    var slug: String
    var description: String?
    /// "Input", "Cached input", "Output" with their dollars; empty when nothing prices the model.
    var prices: [Fact]
    /// The plain-terms cost, "about 3¢" for 1,000 words in and 1,000 out (`example`); nil when nothing prices the model.
    var example: String?
    /// Context and Knowledge.
    var facts: [Fact]
    /// models.dev's input types: text, image, pdf, audio, video.
    var inputs: [String]
    struct Fact: Equatable { var label: String, value: String }

    /// The app's own table first (what the thread cost uses), else models.dev's row for the lab's own provider.
    static func prices(driver: String, slug: String) -> [Fact] {
        if let p = ThreadCostEstimate.price(slug) {
            return [Fact(label: "Input", value: dollars(p.input)), Fact(label: "Cached input", value: dollars(p.cachedInput)),
                    Fact(label: "Output", value: dollars(p.output))]
        }
        guard let p = ModelNotes.note(driver: driver, slug: slug)?.price else { return [] }
        return [Fact(label: "Input", value: dollars(p.input))] + (p.cacheRead.map { [Fact(label: "Cached input", value: dollars($0))] } ?? [])
            + [Fact(label: "Output", value: dollars(p.output))]
    }

    /// The input and output prices per 1M tokens the rows show: the app's table first, else models.dev's.
    static func perMillion(driver: String, slug: String) -> (input: Double, output: Double)? {
        if let p = ThreadCostEstimate.price(slug) { return (p.input, p.output) }
        return ModelNotes.note(driver: driver, slug: slug)?.price.map { ($0.input, $0.output) }
    }

    /// The words in the plain-terms example, each way.
    static let exampleWords = 1_000
    /// Tokens for those words: about 4 tokens per 3 English words, OpenAI's rule of thumb ("1 token is about 3/4 of a
    /// word", help.openai.com "What are tokens"). Anthropic's tokenizer runs a little higher, hence "about".
    static let exampleTokens: Double = Double(exampleWords) * 4 / 3

    /// What 1,000 words in and 1,000 words out cost at these prices, rounded so a reader takes it in at a glance:
    /// "under 1¢", "about 3¢", "about $1.20".
    static func example(input: Double, output: Double) -> String {
        let usd = exampleTokens * (input + output) / 1_000_000
        let cents = (usd * 100).rounded()
        if cents < 1 { return "under 1¢" }
        if cents < 100 { return "about \(Int(cents))¢" }
        return "about " + dollars((usd * 100).rounded() / 100)
    }

    /// "$2", "$0.10", "$1.25", "$0.075": whole dollars bare, cents to two places, a fraction of a cent to three.
    static func dollars(_ v: Double) -> String {
        if v == v.rounded() { return "$\(Int(v))" }
        if (v * 100).rounded() != v * 100 { return String(format: "$%.3f", v) }
        return String(format: "$%.2f", v)
    }

    static func make(_ item: ModelPickerItem) -> ModelDetailContent {
        let slug = item.model.slug, driver = item.entry.driver
        let note = ModelNotes.note(driver: driver, slug: slug)
        return ModelDetailContent(key: item.key, name: ModelNames.display(item.model),
                                  provider: item.model.subProvider.map { "\(item.entry.displayName) · \($0)" } ?? item.entry.displayName,
                                  driver: driver, slug: slug, description: note?.description, prices: prices(driver: driver, slug: slug),
                                  example: perMillion(driver: driver, slug: slug).map { example(input: $0.input, output: $0.output) },
                                  facts: note.map { ModelNotes.facts($0).map { Fact(label: $0.0, value: $0.1) } } ?? [],
                                  inputs: note?.input ?? [])
    }
}

/// The pane at the right of Redesign's picker, after the mockup the user chose (r4-picker-chosen-layout2.png) and their
/// note that the first build was cramped (r4-picker-wip-cramped.png, 2026-11-21): 16pt padding and 16pt between blocks,
/// 8pt from a label to its rows, rows on a 24pt pitch, all on the 4pt grid. Only the name carries weight.
/// Redesign's details card at the right of the model list (the user's layout 2, 2026-11-21, card option 2): a rounded
/// fill step without a rim, the width the reader dragged.
final class ModelDetailPaneView: DSView {
    /// The default width, and the drag's limits: the narrowest that keeps the Reads row and the prices unclipped.
    static let width: CGFloat = 276, minWidth: CGFloat = 240
    static let pad: CGFloat = 16, gap: CGFloat = 16, labelGap: CGFloat = 8, pitch: CGFloat = 24, inputIcon: CGFloat = 16
    /// The plain-terms row's label, for readers to whom a price per 1M tokens means little (the user, 2026-11-21).
    static let exampleLabel = "1,000 words in and out"

    private(set) var content: ModelDetailContent?
    private var card: DitherProviderCardView?
    private let cardLine = CALayer()
    private var icon: NSView?
    private let name = LabelView("", font: DSFont.ui(14, weight: RedesignTokens.Weight.heaviest))
    private let provider = LabelView("", font: DSFont.ui(12))
    private let about = TextBlockView()
    private let priceCaption = LabelView("Price per 1M tokens", font: DSFont.ui(12))
    private var priceRows: [(LabelView, LabelView)] = []
    /// The plain-terms cost under the prices, 8pt below them.
    private var exampleRow: (LabelView, LabelView)?
    private var factRows: [(LabelView, LabelView)] = []
    private var readsLabel: LabelView?
    private var inputIcons: [IconView] = []
    /// What the card says while the list has no model to describe: an empty tab, or a search with no match.
    private let emptyLabel = LabelView("No model to show", font: DSFont.ui(13))

    /// The icon and spoken name for a models.dev input type.
    static func input(_ kind: String) -> (IconName, String)? {
        switch kind {
        case "text": (.type, "Text")
        case "image": (.image, "Images")
        case "pdf": (.fileText, "PDF files")
        case "file": (.file, "Files")
        case "audio": (.music, "Audio")
        case "video": (.film, "Video")
        default: nil
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        layer?.cornerCurve = .continuous
        for l in [cardLine, bottomFade] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "colors": NSNull()]; layer?.addSublayer(l) }
        bottomFade.zPosition = 10
        for l in [name, provider, priceCaption] { l.smoothsFont = false }
        name.lineHeight = 20; provider.lineHeight = 16; priceCaption.lineHeight = 16
        // The whole description shows; `layout` clamps it only when the host's height cannot hold every line.
        about.font = DSFont.ui(13); about.lineHeight = 20; about.smoothsFont = false
        emptyLabel.lineHeight = 20; emptyLabel.alignment = .center; emptyLabel.smoothsFont = false
        for v in [name, provider, about, priceCaption, emptyLabel] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Model details")
        restyle()
    }

    /// Shows `content`; nothing changes when it is the same. `card`: the provider's account card at the top.
    func show(_ content: ModelDetailContent?, card info: DitherProviderCardInfo?) {
        if info != card?.info {
            card?.removeFromSuperview(); card = nil
            if let info { let c = DitherProviderCardView(info: info, onManage: nil); addSubview(c); card = c }
            needsLayout = true
        }
        guard content != self.content else { return }
        self.content = content
        scrollOffset = 0
        icon?.removeFromSuperview(); icon = nil
        for (l, v) in priceRows + factRows + [exampleRow].compactMap({ $0 }) { l.removeFromSuperview(); v.removeFromSuperview() }
        priceRows = []; factRows = []; exampleRow = nil
        readsLabel?.removeFromSuperview(); readsLabel = nil
        inputIcons.forEach { $0.removeFromSuperview() }
        inputIcons = []
        let hidden = content == nil
        for v in [name, provider, about, priceCaption] as [NSView] { v.isHidden = hidden }
        emptyLabel.isHidden = !hidden
        guard let content else { needsLayout = true; return }
        let glyph = ProviderIcon.make(driver: content.driver, displayName: content.provider, size: 16, color: Themed.color(\.contrastForeground), model: true)
        addSubview(glyph); icon = glyph
        name.text = content.name
        provider.text = content.provider
        about.text = content.description ?? ""
        about.isHidden = content.description == nil
        let credit = ModelNotes.source.map { "From \($0.name) (\($0.licence) licence), fetched \($0.fetched)." }
        about.setTooltip(credit)
        about.setAccessibilityLabel(content.description)
        priceRows = content.prices.isEmpty ? [row("No price known", "", credit: nil)] : content.prices.map { row($0.label, $0.value, credit: nil) }
        if let example = content.example {
            let r = row(Self.exampleLabel, example, credit: nil)
            let tip = "What \(ModelDetailContent.exampleWords.formatted()) words of your message and \(ModelDetailContent.exampleWords.formatted()) words of reply cost at the prices above, at about \(Int(ModelDetailContent.exampleTokens).formatted()) tokens each way."
            r.0.setTooltip(tip); r.1.setTooltip(tip)
            exampleRow = r
        }
        factRows = content.facts.map { row($0.label, $0.value, credit: credit) }
        let inputs = content.inputs.compactMap(Self.input)
        if !inputs.isEmpty {
            let l = LabelView("Reads", font: DSFont.ui(12))
            l.lineHeight = 20; l.smoothsFont = false
            addSubview(l)
            readsLabel = l
            l.setAccessibilityLabel("Reads: " + inputs.map(\.1).joined(separator: ", "))
            inputIcons = inputs.map { name, spoken in
                let v = IconView(name: name, size: Self.inputIcon)
                v.setTooltip(spoken)
                v.setAccessibilityElement(true)
                v.setAccessibilityRole(.image)
                v.setAccessibilityLabel(spoken)
                addSubview(v)
                return v
            }
        }
        restyle()
        needsLayout = true
    }

    /// A label at the left and its value at the right in tabular figures.
    private func row(_ label: String, _ value: String, credit: String?) -> (LabelView, LabelView) {
        let l = LabelView(label, font: DSFont.ui(12)), v = LabelView(value, font: DSFont.ui(13).monospacedDigits)
        for x in [l, v] { x.lineHeight = 20; x.smoothsFont = false; addSubview(x) }
        v.alignment = .right
        if !value.isEmpty { l.setAccessibilityLabel("\(label): \(value)") }
        return (l, v)
    }

    /// The pane's height for `content` at `width`, as `layout` places it.
    func height(for content: ModelDetailContent?, card info: DitherProviderCardInfo?, width: CGFloat = ModelDetailPaneView.width) -> CGFloat {
        var y = info.map { DitherProviderCardView.height($0) + 1 } ?? 0
        guard let content else { return y + Self.pad }
        y += Self.pad + 20 + 16
        if let d = content.description {
            // Measures every line, whatever clamp the last layout left on the view.
            let old = about.text, oldMax = about.maxLines
            about.text = d; about.maxLines = 0
            y += Self.gap + about.height(forWidth: width - 2 * Self.pad)
            about.text = old; about.maxLines = oldMax
        }
        y += Self.gap + 16 + Self.labelGap - 2 + CGFloat(max(1, content.prices.count)) * Self.pitch - 2
        if content.example != nil { y += Self.labelGap + Self.pitch }
        let facts = content.facts.count + (content.inputs.contains { Self.input($0) != nil } ? 1 : 0)
        if facts > 0 { y += Self.gap - 2 + CGFloat(facts) * Self.pitch - 2 }
        return y + Self.pad
    }

    /// How far the card is scrolled when its content is taller than the room the popup leaves it.
    private(set) var scrollOffset: CGFloat = 0
    var maxScroll: CGFloat { max(0, height(for: content, card: card?.info, width: bounds.width) - bounds.height) }

    override func scrollWheel(with event: NSEvent) {
        let next = min(max(0, scrollOffset - event.scrollingDeltaY), maxScroll)
        guard next != scrollOffset else { super.scrollWheel(with: event); return }
        scrollOffset = next
        setBoundsOrigin(NSPoint(x: 0, y: scrollOffset))
        placeFade()
    }

    /// A row cut at the card's foot fades out while more is below, so the card reads as scrolling, not clipped.
    private let bottomFade = CAGradientLayer()
    private func placeFade() {
        bottomFade.frame = CGRect(x: 0, y: bounds.maxY - RedesignTokens.Space.l, width: bounds.width, height: RedesignTokens.Space.l)
        bottomFade.isHidden = scrollOffset >= maxScroll - 0.5
    }

    override func layout() {
        super.layout()
        // A new model or a taller card starts at the top again; the offset only survives within the content.
        scrollOffset = min(scrollOffset, maxScroll)
        if bounds.origin.y != scrollOffset { setBoundsOrigin(NSPoint(x: 0, y: scrollOffset)) }
        defer { placeFade() }
        let x = Self.pad, w = bounds.width - 2 * Self.pad
        var y: CGFloat = 0
        if let card {
            card.frame = NSRect(x: 4, y: 0, width: bounds.width - 8, height: card.preferredHeight)
            cardLine.isHidden = false
            cardLine.frame = CGRect(x: x, y: card.frame.maxY, width: w, height: 1)
            y = card.frame.maxY + 1
        } else {
            cardLine.isHidden = true
        }
        if content == nil {
            emptyLabel.frame = NSRect(x: x, y: y + max(Self.pad, (bounds.height - y - 20) / 2), width: w, height: 20)
            return
        }
        y += Self.pad
        icon?.frame = NSRect(x: x, y: y + 2, width: 16, height: 16)
        name.frame = NSRect(x: x + 24, y: y, width: max(0, w - 24), height: 20)
        provider.frame = NSRect(x: x + 24, y: y + 20, width: max(0, w - 24), height: 16)
        y += 36
        if !about.isHidden {
            // The whole description, ending on its own word: when the host caps the popup the card scrolls instead.
            // Clamping it left "Fast Claude model for responsive..." on the new-thread page (C7, round 2).
            about.maxLines = 0
            let h = about.height(forWidth: w)
            about.frame = NSRect(x: x, y: y + Self.gap, width: w, height: h)
            y += Self.gap + h
        }
        // Each row is a 20pt line centered in its 24pt pitch, so blocks still sit 16pt apart.
        y += Self.gap
        priceCaption.frame = NSRect(x: x, y: y, width: w, height: 16)
        y += 16 + Self.labelGap - 2
        y = place(priceRows, from: y, x: x, w: w)
        if let exampleRow { y = place([exampleRow], from: y + Self.labelGap, x: x, w: w) }
        y -= 2
        guard !factRows.isEmpty || readsLabel != nil else { return }
        y += Self.gap - 2
        y = place(factRows, from: y, x: x, w: w)
        if let readsLabel {
            readsLabel.frame = NSRect(x: x, y: y + 2, width: 80, height: 20)
            var right = x + w
            for v in inputIcons.reversed() {
                v.frame = NSRect(x: right - Self.inputIcon, y: y + (Self.pitch - Self.inputIcon) / 2, width: Self.inputIcon, height: Self.inputIcon)
                right -= Self.inputIcon + 8
            }
        }
    }

    private func place(_ rows: [(LabelView, LabelView)], from top: CGFloat, x: CGFloat, w: CGFloat) -> CGFloat {
        var y = top
        for (l, v) in rows {
            let vw = min(ceil(v.textWidth) + 1, w - 96)
            v.frame = NSRect(x: x + w - vw, y: y + 2, width: vw, height: 20)
            l.frame = NSRect(x: x, y: y + 2, width: max(0, w - vw - 12), height: 20)
            y += Self.pitch
        }
        return y
    }

    private func restyle() {
        name.color = Themed.color(\.contrastForeground)
        provider.color = Themed.color(\.contrastMutedForeground)
        about.color = Themed.color(\.contrastMutedForeground)
        priceCaption.color = Themed.color(\.contrastMutedForeground)
        emptyLabel.color = Themed.color(\.contrastMutedForeground)
        for (l, v) in priceRows + factRows + [exampleRow].compactMap({ $0 }) { l.color = Themed.color(\.contrastMutedForeground); v.color = Themed.color(\.contrastForeground) }
        readsLabel?.color = Themed.color(\.contrastMutedForeground)
        for v in inputIcons { v.strokeColor = Themed.color(\.contrastMutedForeground) }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle(); needsDisplay = true }

    override func updateLayer() {
        cardLine.backgroundColor = Themed.color(\.contrastForeground, 0.08).cgColor(in: self)
        // The content ground, a step above the dock's darker ground as the list card is. A surface nested in the popup
        // takes that fill step and no rim of its own: the popup's rim is the only one.
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        bottomFade.colors = [Themed.color(\.background, 0).cgColor(in: self), Themed.color(\.background).cgColor(in: self)]
        layer?.borderWidth = 0
        layer?.cornerRadius = RedesignTokens.Radius.control
    }
}

/// The details card's left edge: a 5pt strip in the gap before the card, with the resize cursor and nothing drawn.
/// Dragging left widens the card; a double-click goes back to the default.
final class ModelDetailPaneResizeHandle: DSView {
    static let hitWidth: CGFloat = 5
    var currentWidth: () -> CGFloat = { 0 }
    var limits: () -> ClosedRange<CGFloat> = { 0...0 }
    /// The width the drag asks for, already clamped; the owner lays out.
    var onResize: ((CGFloat) -> Void)?
    /// The drag ended: the owner saves the width once, not every frame.
    var onCommit: (() -> Void)?
    var onReset: (() -> Void)?
    private var start: (x: CGFloat, width: CGFloat)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize model details")
    }

    /// The width for a drag from `startX` to `x`: the card grows as its left edge moves left.
    static func width(from startWidth: CGFloat, startX: CGFloat, to x: CGFloat, in limits: ClosedRange<CGFloat>) -> CGFloat {
        min(limits.upperBound, max(limits.lowerBound, (startWidth + startX - x).rounded()))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { start = nil; onReset?(); return }
        start = (event.locationInWindow.x, currentWidth())
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onResize?(Self.width(from: start.width, startX: start.x, to: event.locationInWindow.x, in: limits()))
    }
    override func mouseUp(with event: NSEvent) {
        if start != nil { onCommit?() }
        start = nil
    }
    override func accessibilityValue() -> Any? { Int(currentWidth()) }
    override func accessibilityPerformIncrement() -> Bool { step(16) }
    override func accessibilityPerformDecrement() -> Bool { step(-16) }
    private func step(_ delta: CGFloat) -> Bool {
        let l = limits()
        onResize?(min(l.upperBound, max(l.lowerBound, currentWidth() + delta)))
        onCommit?()
        return true
    }
}
