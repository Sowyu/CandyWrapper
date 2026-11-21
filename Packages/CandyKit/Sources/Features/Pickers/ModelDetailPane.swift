import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What Redesign's detail pane shows for one model (the user's layout 2, 2026-11-21): the name and provider,
/// models.dev's one line, the estimated cost in plain words, and models.dev's facts.
struct ModelDetailContent: Equatable {
    var key: String
    var name: String
    var provider: String
    var driver: String
    var slug: String
    var description: String?
    var cost: ModelCostLine
    var facts: [Fact]
    struct Fact: Equatable { var label: String, value: String }

    /// The fixed reference when the highlighted model is the selected one: a model most people here know.
    static let referenceSlug = "claude-sonnet-5-5"

    static func price(driver: String, slug: String) -> (ThreadCostEstimate.Price, fromModelsDev: Bool)? {
        if let p = ThreadCostEstimate.price(slug) { return (p, false) }
        guard let p = ModelNotes.note(driver: driver, slug: slug)?.price else { return nil }
        // Without a cache price, cached input is charged as fresh input: the dearer reading.
        return (ThreadCostEstimate.Price(input: p.input, cachedInput: p.cacheRead ?? p.input, cacheWrite: p.cacheWrite, output: p.output), true)
    }

    /// API key, Bedrock or a custom endpoint bill per token; a signed-in plan, or a provider reporting limit windows, is a
    /// subscription (`auth.type`, ClaudeProvider.ts:189-210, CodexProvider.ts:203-230 at 4928).
    static func billing(_ p: ServerProvider) -> ModelCostLine.Billing {
        let type = p.auth?["type"]?.stringValue?.lowercased()
        if let type, ["apikey", "bedrock", "customendpoint", "vertex"].contains(type) { return .api }
        let label = p.auth?["label"]?.stringValue
        if p.usageLimits?.windows.isEmpty == false || (type != nil && p.auth?["status"]?.stringValue == "authenticated") {
            return .subscription(plan: label)
        }
        return .api
    }

    static func make(_ item: ModelPickerItem, catalog: ProviderCatalog, active: ProviderInstanceId, activeModel: String,
                     turns: (String) -> [Double]) -> ModelDetailContent {
        let slug = item.model.slug, driver = item.entry.driver
        let note = ModelNotes.note(driver: driver, slug: slug)
        let price = price(driver: driver, slug: slug)
        // The selected model is the one people know; on itself the line compares with Sonnet 5.5 when the catalog has it.
        let isActive = item.entry.id == active && slug == activeModel
        let candidates: [(ProviderInstanceEntry, ServerProviderModel)] = catalog.entries.flatMap { e in e.models.map { (e, $0) } }
        let activePair = candidates.first { $0.0.id == active && $0.1.slug == activeModel }
        let fixedPair = candidates.first { $0.1.slug == referenceSlug }
        let referencePair = !isActive ? activePair : (slug == referenceSlug ? nil : fixedPair)
        let reference = referencePair.flatMap { pair in
            Self.price(driver: pair.0.driver, slug: pair.1.slug).map { (name: ModelNames.trigger(pair.1), price: $0.0) }
        }
        var seen = Set<String>()
        let catalogPrices = candidates.filter { $0.0.isReady && seen.insert($0.1.slug).inserted }
            .compactMap { Self.price(driver: $0.0.driver, slug: $0.1.slug)?.0 }
        let name = ModelNames.display(item.model)
        let cost = ModelCostLine.make(.init(modelName: name, price: price?.0, priceFromModelsDev: price?.fromModelsDev ?? false,
                                            ownTurns: turns(slug), reference: reference, catalogPrices: catalogPrices,
                                            billing: billing(item.entry.provider)))
        return ModelDetailContent(key: item.key, name: name,
                                  provider: item.model.subProvider.map { "\(item.entry.displayName) · \($0)" } ?? item.entry.displayName,
                                  driver: driver, slug: slug, description: note?.description, cost: cost,
                                  facts: note.map { ModelNotes.facts($0).map { Fact(label: $0.0, value: $0.1) } } ?? [])
    }
}

/// The pane at the right of Redesign's picker. Facts and the description come from the bundled models.dev snapshot.
final class ModelDetailPaneView: DSView {
    static let width: CGFloat = 212
    static let inset: CGFloat = 14, factHeight: CGFloat = 18

    private(set) var content: ModelDetailContent?
    private var card: DitherProviderCardView?
    private let cardLine = CALayer()
    private let rule = CALayer()
    private var icon: NSView?
    private let name = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let provider = LabelView("", font: DSFont.ui(12))
    private let about = TextBlockView()
    private let costCaption = LabelView("Estimated cost", font: DSFont.ui(11))
    private let headline = LabelView("", font: DSFont.ui(13, weight: .medium))
    private let meter = LabelView("$$$$", font: DSFont.ui(13, weight: .medium))
    private let detail = TextBlockView()
    private let costGroup = DSView()
    private var factLabels: [(LabelView, LabelView)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        for l in [rule, cardLine] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]; layer?.addSublayer(l) }
        for l in [name, provider, costCaption, headline, meter] { l.smoothsFont = false }
        name.lineHeight = 20; provider.lineHeight = 16; costCaption.lineHeight = 14; headline.lineHeight = 18; meter.lineHeight = 18
        about.font = DSFont.ui(12); about.lineHeight = 16; about.maxLines = 3; about.smoothsFont = false
        detail.font = DSFont.ui(11); detail.lineHeight = 14; detail.maxLines = 2; detail.smoothsFont = false
        for v in [name, provider, about, costGroup] as [NSView] { addSubview(v) }
        for v in [costCaption, headline, meter, detail] as [NSView] { costGroup.addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Model details")
        costGroup.setAccessibilityElement(true)
        costGroup.setAccessibilityRole(.staticText)
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
        factLabels.forEach { $0.0.removeFromSuperview(); $0.1.removeFromSuperview() }
        factLabels = []
        guard let content else { name.text = ""; provider.text = ""; about.text = ""; costGroup.isHidden = true; needsLayout = true; return }
        let glyph = ProviderIcon.make(driver: content.driver, displayName: content.provider, size: 16, color: Themed.color(\.contrastForeground), model: true)
        addSubview(glyph); icon = glyph
        name.text = content.name
        provider.text = content.provider
        name.toolTip = "\(content.provider) · \(content.slug)\nReturn picks, Right picks and goes to Reasoning, ⌘1 to ⌘9 jump"
        about.text = content.description ?? ""
        about.isHidden = content.description == nil
        let credit = ModelNotes.source.map { "From \($0.name) (\($0.licence) licence), fetched \($0.fetched)." }
        about.toolTip = credit
        costGroup.isHidden = false
        let c = content.cost
        headline.text = c.headline
        meter.isHidden = c.meter == nil
        detail.text = c.detail ?? ""
        costGroup.toolTip = c.explanation
        costGroup.setAccessibilityLabel("Estimated cost: \(c.accessibilityText)")
        for f in content.facts {
            let l = LabelView(f.label, font: DSFont.ui(12)), v = LabelView(f.value, font: DSFont.ui(12))
            for x in [l, v] { x.lineHeight = 16; x.smoothsFont = false; x.toolTip = credit; addSubview(x) }
            v.alignment = .right
            l.setAccessibilityLabel("\(f.label): \(f.value)")
            factLabels.append((l, v))
        }
        restyle()
        needsLayout = true
    }

    /// The pane's height for `content` at this width, as `layout` places it.
    func height(for content: ModelDetailContent?, card info: DitherProviderCardInfo?) -> CGFloat {
        var y = Self.inset - 2
        if let info { y += DitherProviderCardView.height(info) + 1 + 10 }
        guard let content else { return y }
        y += 20 + 16
        if let d = content.description {
            about.text = d
            y += 8 + about.height(forWidth: Self.width - 2 * Self.inset)
            about.text = self.content?.description ?? ""
        }
        y += 12 + 14 + 18 + (content.cost.detail == nil ? 0 : 2 + measure(content.cost.detail!))
        if !content.facts.isEmpty { y += 12 + CGFloat(content.facts.count) * Self.factHeight }
        return y + Self.inset
    }

    private func measure(_ text: String) -> CGFloat {
        let old = detail.text
        detail.text = text
        defer { detail.text = old }
        return detail.height(forWidth: Self.width - 2 * Self.inset)
    }

    override func layout() {
        super.layout()
        let x = Self.inset, w = bounds.width - 2 * Self.inset
        rule.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        var y = Self.inset - 2
        if let card {
            card.frame = NSRect(x: 4, y: 0, width: bounds.width - 8, height: card.preferredHeight)
            cardLine.isHidden = false
            cardLine.frame = CGRect(x: x, y: card.frame.maxY, width: w, height: 1)
            y = card.frame.maxY + 1 + 10
        } else {
            cardLine.isHidden = true
        }
        icon?.frame = NSRect(x: x, y: y + 2, width: 16, height: 16)
        name.frame = NSRect(x: x + 22, y: y, width: max(0, w - 22), height: 20)
        provider.frame = NSRect(x: x, y: y + 20, width: w, height: 16)
        y += 36
        if !about.isHidden {
            let h = about.height(forWidth: w)
            about.frame = NSRect(x: x, y: y + 8, width: w, height: h)
            y += 8 + h
        }
        let detailH = detail.text.isEmpty ? 0 : detail.height(forWidth: w)
        let groupH = 14 + 18 + (detailH > 0 ? 2 + detailH : 0)
        costGroup.frame = NSRect(x: x, y: y + 12, width: w, height: groupH)
        costCaption.frame = NSRect(x: 0, y: 0, width: w, height: 14)
        if !meter.isHidden {
            let hw = ceil(headline.textWidth)
            headline.frame = NSRect(x: 0, y: 14, width: hw, height: 18)
            meter.frame = NSRect(x: hw + 6, y: 14, width: ceil(meter.textWidth) + 1, height: 18)
        } else {
            headline.frame = NSRect(x: 0, y: 14, width: w, height: 18)
        }
        detail.frame = NSRect(x: 0, y: 34, width: w, height: detailH)
        y += 12 + groupH
        if !factLabels.isEmpty { y += 12 }
        for (l, v) in factLabels {
            let vw = min(ceil(v.textWidth) + 1, w - 60)
            v.frame = NSRect(x: x + w - vw, y: y + 1, width: vw, height: 16)
            l.frame = NSRect(x: x, y: y + 1, width: max(0, w - vw - 8), height: 16)
            y += Self.factHeight
        }
    }

    private func restyle() {
        name.color = Themed.color(\.contrastForeground)
        provider.color = Themed.color(\.contrastMutedForeground)
        about.color = Themed.color(\.contrastForeground, 0.78)
        costCaption.color = Themed.color(\.contrastMutedForeground)
        headline.color = Themed.color(\.contrastForeground)
        meter.color = Themed.color(\.contrastForeground, 0.22)
        meter.prefixColor = content?.cost.meter.map { ($0, Themed.color(\.contrastForeground)) }
        detail.color = Themed.color(\.contrastMutedForeground)
        (icon as? IconView)?.strokeColor = Themed.color(\.contrastForeground)
        for (l, v) in factLabels { l.color = Themed.color(\.contrastMutedForeground); v.color = Themed.color(\.contrastForeground) }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle(); needsDisplay = true }

    override func updateLayer() {
        let line = Themed.color(\.contrastForeground, 0.08).cgColor(in: self)
        rule.backgroundColor = line
        cardLine.backgroundColor = line
    }
}
