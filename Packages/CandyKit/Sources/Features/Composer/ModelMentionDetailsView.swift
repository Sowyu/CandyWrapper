import AppKit
import DesignSystem

/// The model chip's details (`ModelMentionChip`'s `ContextChipPopover`, chat/ModelMentionChip.tsx:100-125 at
/// 4928): `space-y-1 p-2 text-sm` with the model in medium, its provider muted and the source in 12px mono.
public final class ModelMentionDetailsView: DSView {
    /// Each `<p>` wraps, breaking after a hyphen as the browser does, so a long source takes another line.
    private let rows: [TextBlockView]

    public init(label: String, provider: String, source: String) {
        func row(_ text: String, _ font: NSFont, _ color: NSColor, _ lineHeight: CGFloat) -> TextBlockView {
            let block = TextBlockView()
            block.text = text; block.font = font; block.color = color; block.lineHeight = lineHeight
            return block
        }
        rows = [row(label, DSFont.ui(14, weight: .medium), Themed.color(\.contrastPopoverForeground), 20),
                row(provider, DSFont.ui(14), Themed.color(\.mutedForeground), 20),
                row(source, DSFont.mono(12), Themed.color(\.mutedForeground), 16)]
        super.init(frame: .zero)
        rows.forEach(addSubview)
        setAccessibilityLabel("Model \(label)")
    }

    /// The `lg` popover's content box: `w-96` less its border and the compact padding.
    private static let width: CGFloat = 384 - 2 - 24

    private func heights(_ width: CGFloat) -> [CGFloat] { rows.map { $0.height(forWidth: max(0, width - 16)) } }

    public override var intrinsicContentSize: NSSize {
        let h = heights(Self.width)
        return NSSize(width: Self.width, height: 8 + h.reduce(0, +) + 4 * CGFloat(h.count - 1) + 8)
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 8
        for (row, height) in zip(rows, heights(bounds.width)) {
            row.frame = NSRect(x: 8, y: y, width: max(0, bounds.width - 16), height: height)
            y += height + 4
        }
    }

    /// Opens over `anchor` (the chip), `side="top" width="lg" padding="compact"`.
    @discardableResult
    public static func show(label: String, provider: String, source: String, from anchor: NSView) -> OpenPopup? {
        PopoverView(content: ModelMentionDetailsView(label: label, provider: provider, source: source), padding: .compact, width: .lg)
            .show(from: anchor, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
    }
}
