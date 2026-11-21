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
                                  facts: note.map { ModelNotes.facts($0).map { Fact(label: $0.0, value: $0.1) } } ?? [],
                                  inputs: note?.input ?? [])
    }
}

/// The pane at the right of Redesign's picker, after the mockup the user chose (r4-picker-chosen-layout2.png) and their
/// note that the first build was cramped (r4-picker-wip-cramped.png, 2026-11-21): 16pt padding and 16pt between blocks,
/// 8pt from a label to its rows, rows on a 24pt pitch, all on the 4pt grid. Only the name carries weight.
final class ModelDetailPaneView: DSView {
    static let width: CGFloat = 288
    static let pad: CGFloat = 16, gap: CGFloat = 16, labelGap: CGFloat = 8, pitch: CGFloat = 24, inputIcon: CGFloat = 16

    private(set) var content: ModelDetailContent?
    private var card: DitherProviderCardView?
    private let cardLine = CALayer()
    private let rule = CALayer()
    private var icon: NSView?
    private let name = LabelView("", font: DSFont.ui(14, weight: .semibold))
    private let provider = LabelView("", font: DSFont.ui(12))
    private let about = TextBlockView()
    private let priceCaption = LabelView("Price per 1M tokens", font: DSFont.ui(12))
    private var priceRows: [(LabelView, LabelView)] = []
    private var factRows: [(LabelView, LabelView)] = []
    private var readsLabel: LabelView?
    private var inputIcons: [IconView] = []
    private var contentWidth: CGFloat { Self.width - 2 * Self.pad }

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
        for l in [rule, cardLine] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]; layer?.addSublayer(l) }
        for l in [name, provider, priceCaption] { l.smoothsFont = false }
        name.lineHeight = 20; provider.lineHeight = 16; priceCaption.lineHeight = 16
        about.font = DSFont.ui(13); about.lineHeight = 20; about.maxLines = 2; about.smoothsFont = false
        for v in [name, provider, about, priceCaption] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Model details")
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
        icon?.removeFromSuperview(); icon = nil
        for (l, v) in priceRows + factRows { l.removeFromSuperview(); v.removeFromSuperview() }
        priceRows = []; factRows = []
        readsLabel?.removeFromSuperview(); readsLabel = nil
        inputIcons.forEach { $0.removeFromSuperview() }
        inputIcons = []
        let hidden = content == nil
        for v in [name, provider, about, priceCaption] as [NSView] { v.isHidden = hidden }
        guard let content else { needsLayout = true; return }
        let glyph = ProviderIcon.make(driver: content.driver, displayName: content.provider, size: 16, color: Themed.color(\.contrastForeground), model: true)
        addSubview(glyph); icon = glyph
        name.text = content.name
        provider.text = content.provider
        name.toolTip = "\(content.provider) · \(content.slug)\nReturn picks, Right picks and goes to Reasoning, ⌘1 to ⌘9 jump"
        about.text = content.description ?? ""
        about.isHidden = content.description == nil
        let credit = ModelNotes.source.map { "From \($0.name) (\($0.licence) licence), fetched \($0.fetched)." }
        // Two lines show; the tooltip and VoiceOver get the whole description.
        about.toolTip = [content.description, credit].compactMap { $0 }.joined(separator: "\n\n")
        about.setAccessibilityLabel(content.description)
        priceRows = content.prices.isEmpty ? [row("No price known", "", credit: nil)] : content.prices.map { row($0.label, $0.value, credit: nil) }
        factRows = content.facts.map { row($0.label, $0.value, credit: credit) }
        let inputs = content.inputs.compactMap(Self.input)
        if !inputs.isEmpty {
            let l = LabelView("Reads", font: DSFont.ui(12))
            l.lineHeight = 20; l.smoothsFont = false; l.toolTip = credit
            addSubview(l)
            readsLabel = l
            l.setAccessibilityLabel("Reads: " + inputs.map(\.1).joined(separator: ", "))
            inputIcons = inputs.map { name, spoken in
                let v = IconView(name: name, size: Self.inputIcon)
                v.toolTip = spoken
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
        for x in [l, v] { x.lineHeight = 20; x.smoothsFont = false; x.toolTip = credit; addSubview(x) }
        v.alignment = .right
        if !value.isEmpty { l.setAccessibilityLabel("\(label): \(value)") }
        return (l, v)
    }

    /// The pane's height for `content`, as `layout` places it.
    func height(for content: ModelDetailContent?, card info: DitherProviderCardInfo?) -> CGFloat {
        var y = info.map { DitherProviderCardView.height($0) + 1 } ?? 0
        guard let content else { return y + Self.pad }
        y += Self.pad + 20 + 16
        if let d = content.description {
            let old = about.text
            about.text = d
            y += Self.gap + about.height(forWidth: contentWidth)
            about.text = old
        }
        y += Self.gap + 16 + Self.labelGap - 2 + CGFloat(max(1, content.prices.count)) * Self.pitch - 2
        let facts = content.facts.count + (content.inputs.contains { Self.input($0) != nil } ? 1 : 0)
        if facts > 0 { y += Self.gap - 2 + CGFloat(facts) * Self.pitch - 2 }
        return y + Self.pad
    }

    override func layout() {
        super.layout()
        let x = Self.pad, w = bounds.width - 2 * Self.pad
        rule.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        var y: CGFloat = 0
        if let card {
            card.frame = NSRect(x: 4, y: 0, width: bounds.width - 8, height: card.preferredHeight)
            cardLine.isHidden = false
            cardLine.frame = CGRect(x: x, y: card.frame.maxY, width: w, height: 1)
            y = card.frame.maxY + 1
        } else {
            cardLine.isHidden = true
        }
        y += Self.pad
        icon?.frame = NSRect(x: x, y: y + 2, width: 16, height: 16)
        name.frame = NSRect(x: x + 24, y: y, width: max(0, w - 24), height: 20)
        provider.frame = NSRect(x: x + 24, y: y + 20, width: max(0, w - 24), height: 16)
        y += 36
        if !about.isHidden {
            let h = about.height(forWidth: w)
            about.frame = NSRect(x: x, y: y + Self.gap, width: w, height: h)
            y += Self.gap + h
        }
        // Each row is a 20pt line centered in its 24pt pitch, so blocks still sit 16pt apart.
        y += Self.gap
        priceCaption.frame = NSRect(x: x, y: y, width: w, height: 16)
        y += 16 + Self.labelGap - 2
        y = place(priceRows, from: y, x: x, w: w) - 2
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
        for (l, v) in priceRows + factRows { l.color = Themed.color(\.contrastMutedForeground); v.color = Themed.color(\.contrastForeground) }
        readsLabel?.color = Themed.color(\.contrastMutedForeground)
        for v in inputIcons { v.strokeColor = Themed.color(\.contrastMutedForeground) }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle(); needsDisplay = true }

    override func updateLayer() {
        let line = Themed.color(\.contrastForeground, 0.08).cgColor(in: self)
        rule.backgroundColor = line
        cardLine.backgroundColor = line
    }
}
