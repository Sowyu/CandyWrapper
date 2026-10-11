import AppKit
import CoreText
import DesignSystem
import T3Protocol

/// Text drawn straight into a context, for the tables (a label per cell would cost 500 views at 90 days).
@MainActor
enum UsageText {
    static func line(_ text: String, _ font: NSFont, _ color: NSColor) -> TextLine {
        TextLine(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }

    static func width(_ text: String, _ font: NSFont) -> CGFloat { line(text, font, .black).width }

    /// Draws one line in `rect`, placed like CSS in a `lineHeight` box at the rect's top, truncated with an ellipsis.
    static func draw(_ ctx: CGContext, _ text: String, font: NSFont, color: NSColor, in rect: CGRect, lineHeight: CGFloat,
                     align: NSTextAlignment = .left) {
        guard !text.isEmpty else { return }
        let full = line(text, font, color)
        var ctLine = full.line
        var width = full.width
        if width > rect.width, rect.width > 0,
           let t = CTLineCreateTruncatedLine(full.line, Double(rect.width), .end,
                                             CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [.font: font, .foregroundColor: color]))) {
            ctLine = t
            width = CGFloat(CTLineGetTypographicBounds(t, nil, nil, nil))
        }
        let x: CGFloat = align == .right ? rect.maxX - width : align == .center ? rect.midX - width / 2 : rect.minX
        let baseline = full.baseline(top: rect.minY, lineHeight: lineHeight)
        ctx.saveGState()
        ctx.setShouldSmoothFonts(true)
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }
}

/// The Breakdown tables (UsagePage.tsx:795-982): by model, with the share dash under each name and the
/// whole row opening the model; or by day or hour, newest first, with a column per active provider.
public final class UsageBreakdownTableView: DSView {
    public struct ModelRow: Equatable {
        public var key: String
        public var provider: UsageProviderKind
        public var model: String
        public var cost: String
        public var costMuted: Bool
        public var share: String
        public var tokens: String
        /// Bar width as a fraction of the peak, 0 hides it.
        public var fraction: Double
        public var loading: Bool
    }
    public struct PeriodRow: Equatable {
        public var label: String
        public var providers: [String]
        public var providerLoading: [Bool]
        public var total: String
        public var tokens: String
    }
    public enum Content: Equatable {
        case models([ModelRow])
        case periods(header: String, providers: [UsageProviderKind], rows: [PeriodRow], loading: Bool)
    }

    public var content: Content = .models([]) { didSet { if content != oldValue { cacheIcons(); needsDisplay = true; onHeightChange?() } } }
    /// `sm:table-cell`: the Share column shows from 640pt.
    public var showsShare = true { didSet { if showsShare != oldValue { needsDisplay = true } } }
    public var onSelect: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    private var hoverRow: Int? {
        didSet {
            guard hoverRow != oldValue else { return }
            // `transition-colors hover:bg-muted/50` (UsagePage.tsx:853,940): the rows are one drawing, so cross-fade it.
            if window != nil, !Motion.reduced, let layer { Motion.crossfade(layer) }
            needsDisplay = true
        }
    }
    private var icons: [UsageProviderKind: NSView] = [:]
    private var tracking: NSTrackingArea?

    static let headerHeight: CGFloat = 33
    static let modelRowHeight: CGFloat = 49
    static let periodRowHeight: CGFloat = 37
    static let emptyHeight: CGFloat = 33 + 1 + 24 + 20

    public override var wantsUpdateLayer: Bool { false }

    public func height(forWidth width: CGFloat) -> CGFloat {
        switch content {
        case .models(let rows): rows.isEmpty ? Self.emptyHeight : Self.headerHeight + CGFloat(rows.count) * Self.modelRowHeight
        case .periods(_, _, let rows, _): rows.isEmpty ? Self.emptyHeight : Self.headerHeight + CGFloat(rows.count) * Self.periodRowHeight
        }
    }

    /// Provider marks are icon views (the Claude glyph is multicolor); they sit over the drawn rows.
    private func cacheIcons() {
        icons.values.forEach { $0.removeFromSuperview() }
        icons = [:]
        subviews.forEach { $0.removeFromSuperview() }
        guard case .models(let rows) = content else { return }
        for r in rows {
            let v = UsageStyle.mark(r.provider, size: 14, color: Themed.color(\.foreground))
            v.identifier = NSUserInterfaceItemIdentifier(r.key)
            addSubview(v)
        }
        needsLayout = true
    }

    private var modelColumns: (index: CGFloat, cost: CGFloat, share: CGFloat, tokens: CGFloat) {
        guard case .models(let rows) = content else { return (0, 0, 0, 0) }
        let f14 = UsageStyle.tabular(14), f12 = UsageStyle.tabular(12)
        let index = max(UsageText.width("#", DSFont.ui(12)), UsageText.width("\(rows.count)", f12)) + 12
        let cost = max(UsageText.width("Cost", DSFont.ui(12)), rows.map { UsageText.width($0.cost, f14) }.max() ?? 0) + 24
        let share = showsShare ? max(UsageText.width("Share", DSFont.ui(12)), rows.map { UsageText.width($0.share, f14) }.max() ?? 0) + 24 : 0
        let tokens = max(UsageText.width("Tokens", DSFont.ui(12)), rows.map { UsageText.width($0.tokens, f14) }.max() ?? 0) + 24
        return (ceil(index), ceil(cost), ceil(share), ceil(tokens))
    }

    public override func layout() {
        super.layout()
        guard case .models(let rows) = content else { return }
        let cols = modelColumns
        for (i, r) in rows.enumerated() {
            guard let v = subviews.first(where: { $0.identifier?.rawValue == r.key }) else { continue }
            let y = Self.headerHeight + CGFloat(i) * Self.modelRowHeight + 10
            v.frame = NSRect(x: cols.index, y: y + 3, width: 14, height: 14)
            v.alphaValue = r.loading ? 0.4 : 1
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func row(at p: CGPoint) -> Int? {
        let h: CGFloat
        let count: Int
        switch content {
        case .models(let rows): h = Self.modelRowHeight; count = rows.count
        case .periods(_, _, let rows, _): h = Self.periodRowHeight; count = rows.count
        }
        guard p.y >= Self.headerHeight else { return nil }
        let i = Int((p.y - Self.headerHeight) / h)
        return i < count ? i : nil
    }

    public override func mouseMoved(with event: NSEvent) { hoverRow = row(at: convert(event.locationInWindow, from: nil)) }
    public override func mouseExited(with event: NSEvent) { hoverRow = nil }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        guard case .models(let rows) = content, let i = row(at: convert(event.locationInWindow, from: nil)) else { return }
        onSelect?(rows[i].key)
    }
    public override func resetCursorRects() {
        if case .models(let rows) = content, !rows.isEmpty {
            addCursorRect(NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: bounds.height - Self.headerHeight), cursor: .pointingHand)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let muted = Themed.color(\.mutedForeground), fg = Themed.color(\.foreground)
        let head = DSFont.ui(12), body = UsageStyle.tabular(14), small = UsageStyle.tabular(12)
        func rule(_ y: CGFloat, strong: Bool) {
            ctx.setFillColor(Themed.color(\.border, strong ? 1 : 0.5).cgColor(in: self))
            ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
        }
        func empty(_ y: CGFloat) {
            UsageText.draw(ctx, "No activity in this window.", font: DSFont.ui(14), color: muted, in: CGRect(x: 0, y: y + 24, width: w, height: 20),
                           lineHeight: 20, align: .center)
        }
        switch content {
        case .models(let rows):
            let c = modelColumns
            let tokensX = w - c.tokens, shareX = tokensX - c.share, costX = shareX - c.cost
            UsageText.draw(ctx, "#", font: head, color: muted, in: CGRect(x: 0, y: 8, width: c.index, height: 16), lineHeight: 16)
            UsageText.draw(ctx, "Model", font: head, color: muted, in: CGRect(x: c.index, y: 8, width: costX - c.index, height: 16), lineHeight: 16)
            UsageText.draw(ctx, "Cost", font: head, color: muted, in: CGRect(x: costX, y: 8, width: c.cost, height: 16), lineHeight: 16, align: .right)
            if showsShare { UsageText.draw(ctx, "Share", font: head, color: muted, in: CGRect(x: shareX, y: 8, width: c.share, height: 16), lineHeight: 16, align: .right) }
            UsageText.draw(ctx, "Tokens", font: head, color: muted, in: CGRect(x: tokensX, y: 8, width: c.tokens, height: 16), lineHeight: 16, align: .right)
            rule(32, strong: true)
            if rows.isEmpty { empty(33); return }
            for (i, r) in rows.enumerated() {
                let y = Self.headerHeight + CGFloat(i) * Self.modelRowHeight
                if hoverRow == i {
                    ctx.setFillColor(Themed.color(\.muted, 0.5).cgColor(in: self))
                    ctx.fill(CGRect(x: 0, y: y, width: w, height: Self.modelRowHeight - 1))
                }
                let dim: CGFloat = r.loading ? 0.4 : 1
                UsageText.draw(ctx, "\(i + 1)", font: small, color: muted, in: CGRect(x: 0, y: y + 10, width: c.index, height: 20), lineHeight: 20)
                UsageText.draw(ctx, r.model, font: DSFont.ui(14), color: fg, in: CGRect(x: c.index + 22, y: y + 10, width: costX - c.index - 22, height: 20),
                               lineHeight: 20)
                if r.fraction > 0 {
                    let barW = min(192, max(8, CGFloat(r.fraction) * min(192, costX - c.index)))
                    ctx.setFillColor(UsageStyle.color(r.provider).withAlphaComponent(dim).cgColor(in: self))
                    ctx.addPath(CGPath(roundedRect: CGRect(x: c.index, y: y + 36, width: barW, height: 2), cornerWidth: 1, cornerHeight: 1, transform: nil))
                    ctx.fillPath()
                }
                UsageText.draw(ctx, r.cost, font: body, color: (r.costMuted ? muted : fg).withAlphaComponent(dim),
                               in: CGRect(x: costX, y: y + 10, width: c.cost, height: 20), lineHeight: 20, align: .right)
                if showsShare {
                    UsageText.draw(ctx, r.share, font: body, color: muted.withAlphaComponent(dim), in: CGRect(x: shareX, y: y + 10, width: c.share, height: 20),
                                   lineHeight: 20, align: .right)
                }
                UsageText.draw(ctx, r.tokens, font: body, color: muted.withAlphaComponent(dim), in: CGRect(x: tokensX, y: y + 10, width: c.tokens, height: 20),
                               lineHeight: 20, align: .right)
                rule(y + Self.modelRowHeight - 1, strong: false)
            }
        case .periods(let header, let providers, let rows, let loading):
            let first = w * 0.4
            let colW = (w - first) / CGFloat(providers.count + 2)
            let titles = [header] + providers.map(\.label) + ["Total", "Tokens"]
            for (i, t) in titles.enumerated() {
                let x = i == 0 ? 0 : first + CGFloat(i - 1) * colW
                UsageText.draw(ctx, t, font: head, color: muted, in: CGRect(x: x, y: 8, width: i == 0 ? first : colW, height: 16), lineHeight: 16,
                               align: i == 0 ? .left : .right)
            }
            rule(32, strong: true)
            if rows.isEmpty { empty(33); return }
            for (i, r) in rows.enumerated() {
                let y = Self.headerHeight + CGFloat(i) * Self.periodRowHeight
                if hoverRow == i {
                    ctx.setFillColor(Themed.color(\.muted, 0.5).cgColor(in: self))
                    ctx.fill(CGRect(x: 0, y: y, width: w, height: Self.periodRowHeight - 1))
                }
                UsageText.draw(ctx, r.label, font: DSFont.ui(14), color: fg, in: CGRect(x: 0, y: y + 8, width: first, height: 20), lineHeight: 20)
                for (j, v) in r.providers.enumerated() {
                    let dim: CGFloat = j < r.providerLoading.count && r.providerLoading[j] ? 0.4 : 1
                    UsageText.draw(ctx, v, font: body, color: muted.withAlphaComponent(dim),
                                   in: CGRect(x: first + CGFloat(j) * colW, y: y + 8, width: colW, height: 20), lineHeight: 20, align: .right)
                }
                let dim: CGFloat = loading ? 0.4 : 1
                UsageText.draw(ctx, r.total, font: body, color: fg.withAlphaComponent(dim),
                               in: CGRect(x: first + CGFloat(providers.count) * colW, y: y + 8, width: colW, height: 20), lineHeight: 20, align: .right)
                UsageText.draw(ctx, r.tokens, font: body, color: muted.withAlphaComponent(dim),
                               in: CGRect(x: first + CGFloat(providers.count + 1) * colW, y: y + 8, width: colW, height: 20), lineHeight: 20, align: .right)
                rule(y + Self.periodRowHeight - 1, strong: false)
            }
        }
    }
}
