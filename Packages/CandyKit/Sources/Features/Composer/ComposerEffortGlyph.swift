import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// T3 3824 EffortGlyph.tsx:19-49. Named workflow levels stay words in either display mode.
struct ComposerEffort: Equatable {
    var count: Int
    var filled: Int
    var label: String
    var special: Bool

    static func resolve(_ descriptor: ProviderOptionDescriptor, current: String?) -> Self? {
        let special = Set((descriptor.promptInjectedValues ?? []) + ["ultracode", "max"])
        let levels = descriptor.options.filter { !special.contains($0.id) }
        guard levels.count >= 2, let current else { return nil }
        let off = ["off", "none"].contains(levels[0].id)
        let count = levels.count - (off ? 1 : 0)
        if special.contains(current) {
            return Self(count: count, filled: count, label: descriptor.options.first { $0.id == current }?.label ?? current, special: true)
        }
        guard let index = levels.firstIndex(where: { $0.id == current }) else { return nil }
        return Self(count: count, filled: off ? index : index + 1, label: levels[index].label, special: false)
    }

    static func heights(count: Int, maximum: Int = 12) -> [Int] {
        let step = max(1, Int((Double(maximum) / 2 / Double(max(count - 1, 1))).rounded()))
        return (0..<count).map { maximum - (count - 1 - $0) * step }
    }
}

final class ComposerEffortGlyphView: DSView {
    let effort: ComposerEffort
    var color = Themed.color(\.mutedForeground) { didSet { needsDisplay = true } }
    init(_ effort: ComposerEffort) { self.effort = effort; super.init(frame: .zero) }
    override var intrinsicContentSize: NSSize { NSSize(width: effort.count * 4 - 2, height: 14) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (i, height) in ComposerEffort.heights(count: effort.count).enumerated() {
            ctx.setFillColor(color.cgColor(in: self))
            ctx.setAlpha(i < effort.filled ? 1 : 0.4)
            ctx.fill(CGRect(x: i * 4, y: 12 - height, width: 2, height: height))
        }
    }
}

/// 3824 TraitsPicker.tsx:514-535. Ultrafast echoes an outlined bolt behind the filled one.
final class ComposerFastGlyphView: DSView {
    let ultra: Bool
    var color = Themed.color(\.mutedForeground) { didSet { needsDisplay = true } }
    init(ultra: Bool) { self.ultra = ultra; super.init(frame: .zero) }
    override var intrinsicContentSize: NSSize { NSSize(width: ultra ? 15 : 12, height: 12) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ink = color.cgColor(in: self)
        var bolt = IconName.zap.definition
        if ultra { MarkdownView.drawIcon(bolt, in: CGRect(x: 3, y: 0, width: 12, height: 12), color: ink, ctx: ctx) }
        bolt.elements = bolt.elements.map { var e = $0; e.paint.fill = .current; return e }
        if ultra {
            var cutout = bolt
            cutout.elements = cutout.elements.map { var e = $0; e.paint.strokeWidth = 4; return e }
            MarkdownView.drawIcon(cutout, in: CGRect(x: 0, y: 0, width: 12, height: 12), color: Themed.color(\.surfaceRaised).cgColor(in: self), ctx: ctx)
        }
        MarkdownView.drawIcon(bolt, in: CGRect(x: 0, y: 0, width: 12, height: 12), color: ink, ctx: ctx)
    }
}

final class ComposerTraitsAdornmentView: DSView {
    private let speed: ComposerFastGlyphView?
    private let label: LabelView?
    var showsLabels = true { didSet { label?.isHidden = !showsLabels; needsLayout = true } }
    var color = Themed.color(\.mutedForeground) { didSet { speed?.color = color; label?.color = color } }
    init(ultra: Bool?, labels: [String]) {
        speed = ultra.map { ComposerFastGlyphView(ultra: $0) }
        label = labels.isEmpty ? nil : LabelView(labels.joined(separator: " · "), font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        if let speed { addSubview(speed) }
        if let label { label.lineHeight = 16; label.smoothsFont = false; addSubview(label) }
    }
    func width(showingLabel: Bool) -> CGFloat {
        (speed?.intrinsicContentSize.width ?? 0) + (showingLabel ? label.map { min(96, ceil($0.textWidth)) } ?? 0 : 0) + (speed != nil && label != nil && showingLabel ? 6 : 0)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: width(showingLabel: showsLabels), height: 16) }
    override func layout() {
        super.layout()
        let width = speed?.intrinsicContentSize.width ?? 0
        speed?.frame = NSRect(x: 0, y: 2, width: width, height: 12)
        if let label { let x = width + (speed == nil ? 0 : 6); label.frame = NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: 16) }
    }
}
