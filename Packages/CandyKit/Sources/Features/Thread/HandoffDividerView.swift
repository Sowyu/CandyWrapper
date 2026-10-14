import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `HandoffRow` (chat/V2LifecycleRow.tsx:549-590): a `TimelineSystemDivider` labeled "Context handoff", or
/// "Context handoff pending" in the timeline footer while the composer's model needs one (ChatView.tsx:11588-11603),
/// with the source models, an arrow and the target model. 40pt: `py-2` around the 24pt pill.
@MainActor
final class HandoffDividerView: DSView {
    static let height: CGFloat = 40

    private let leftRule = FillView(), rightRule = FillView()
    private let icon = IconView(name: .arrowRightLeft, size: 12)
    private let label = LabelView("", font: TL.font(11, .medium))
    /// The detail's `opacity-70` span.
    private let detail = DSView()
    private var parts: [(view: NSView, width: CGFloat, gap: CGFloat, label: LabelView?)] = []
    private var endpoints: HandoffEndpoints?
    private var providers: [ServerProvider] = []
    private var failed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for r in [leftRule, rightRule] { r.fill = TL.c(\.border, 0.7); addSubview(r) }
        label.lineHeight = 16
        detail.alphaValue = 0.7
        for v in [icon, label, detail] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ endpoints: HandoffEndpoints, providers: [ServerProvider], pending: Bool = false, failed: Bool = false) {
        label.text = pending ? "Context handoff pending" : "Context handoff"
        let tone = failed ? TL.c(\.destructive) : TL.c(\.mutedForeground)
        label.color = tone
        icon.strokeColor = tone
        guard endpoints != self.endpoints || providers != self.providers || failed != self.failed else { return }
        self.endpoints = endpoints
        self.providers = providers
        self.failed = failed
        parts.forEach { $0.view.removeFromSuperview() }
        parts = []
        for (i, endpoint) in endpoints.from.enumerated() {
            if i > 0 {
                // `-ml-1` on the comma.
                let comma = LabelView(",", font: TL.font(11), color: tone)
                comma.lineHeight = 16
                parts.append((comma, ceil(comma.textWidth), 2, nil))
            }
            appendEndpoint(endpoint, tone: tone, gap: i > 0 ? 6 : 0)
        }
        if !endpoints.from.isEmpty { parts.append((IconView(name: .arrowRight, size: 12, strokeColor: tone), 12, 6, nil)) }
        appendEndpoint(endpoints.to, tone: tone, gap: endpoints.from.isEmpty ? 0 : 6)
        parts.forEach { detail.addSubview($0.view) }
        needsLayout = true
    }

    /// `HandoffEndpoint` (V2LifecycleRow.tsx:592-640): the instance's glyph and the model's trigger name in the
    /// provider's brand color, else the model slug, else the instance name. Hover shows "<instance> · <model>".
    private func appendEndpoint(_ endpoint: HandoffEndpoints.Endpoint, tone: NSColor, gap: CGFloat) {
        let provider = providers.first { $0.instanceId == endpoint.instanceId }
        let entry = ProviderCatalog(providers).entry(endpoint.instanceId)
        let model = endpoint.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = entry?.displayName ?? endpoint.instanceId.rawValue
        let text = model.flatMap { m in entry?.models.first { $0.slug == m }.map(ModelNames.trigger) }
            ?? (model?.isEmpty == false ? model! : name)
        let driver = provider?.driver ?? endpoint.instanceId.rawValue
        let box = DSView()
        let glyph = ProviderIcon.make(driver: driver, displayName: name, size: 12, color: tone)
        glyph.frame = NSRect(x: 0, y: 2, width: 12, height: 12)
        let l = LabelView(text, font: TL.font(11, .medium), color: Self.brandColor(driver) ?? tone)
        l.lineHeight = 16
        box.addSubview(glyph)
        box.addSubview(l)
        box.toolTip = "\(name) · \(text)"
        parts.append((box, 12 + 4 + ceil(l.textWidth), gap, l))
    }

    /// `providerTextColor` (chat/ProviderInstanceIcon.tsx:23-43).
    static func brandColor(_ driver: String) -> NSColor? {
        switch driver {
        case "codex": NSColor(name: nil) { $0.isDark ? .white : .black }
        case "claudeAgent": NSColor(srgbRed: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        case "antigravity": NSColor(srgbRed: 0x5b / 255, green: 0x87 / 255, blue: 0xbf / 255, alpha: 1)
        default: nil
        }
    }

    override func layout() {
        super.layout()
        // `gap-1.5 rounded-full px-2 py-1` centered between two rules with `gap-2`; the detail follows the label
        // with `gap-1.5` and no separator.
        let lw = ceil(label.textWidth)
        var dw = parts.reduce(0) { $0 + $1.gap + $1.width }
        // ponytail: endpoint names shrink evenly when the lane is too narrow, where T3 wraps the pill; wrap if long model names show up
        let room = max(0, bounds.width - 32 - (8 + 12 + 6 + lw + 6 + 8))
        let labelled = parts.filter { $0.label != nil }
        let excess = max(0, dw - room), cut = labelled.isEmpty ? 0 : ceil(excess / CGFloat(labelled.count))
        if excess > 0 { dw -= cut * CGFloat(labelled.count) }
        let pw = 8 + 12 + 6 + lw + (parts.isEmpty ? 0 : 6 + dw) + 8
        let x = ((bounds.width - pw) / 2).rounded()
        let top = (bounds.height - 24) / 2
        leftRule.frame = NSRect(x: 0, y: top + 12, width: max(0, x - 8), height: 1)
        rightRule.frame = NSRect(x: x + pw + 8, y: top + 12, width: max(0, bounds.width - x - pw - 8), height: 1)
        icon.frame = NSRect(x: x + 8, y: top + 6, width: 12, height: 12)
        label.frame = NSRect(x: x + 8 + 18, y: top + 4, width: lw, height: 16)
        detail.frame = NSRect(x: label.frame.maxX + 6, y: top + 4, width: dw, height: 16)
        var px: CGFloat = 0
        for part in parts {
            px += part.gap
            let w = part.label == nil ? part.width : max(16, part.width - cut)
            part.view.frame = part.view is IconView ? NSRect(x: px, y: 2, width: 12, height: 12)
                : NSRect(x: px, y: 0, width: w, height: 16)
            part.label?.frame = NSRect(x: 16, y: 0, width: max(0, w - 16), height: 16)
            px += w
        }
    }
}
