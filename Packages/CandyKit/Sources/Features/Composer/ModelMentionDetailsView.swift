import AppKit
import DesignSystem

/// The model chip's details (`ModelMentionChip`'s `ContextChipPopover`, chat/ModelMentionChip.tsx:100-125 at
/// 4928): `space-y-1 p-2 text-sm` with the model in medium, its provider muted and the source in 12px mono.
public final class ModelMentionDetailsView: DSView {
    private let rows: [LabelView]

    public init(label: String, provider: String, source: String) {
        let title = LabelView(label, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.contrastPopoverForeground))
        let sub = LabelView(provider, font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
        let code = LabelView(source, font: DSFont.mono(12), color: Themed.color(\.mutedForeground))
        title.lineHeight = 20; sub.lineHeight = 20; code.lineHeight = 16
        rows = [title, sub, code]
        super.init(frame: .zero)
        rows.forEach(addSubview)
        setAccessibilityLabel("Model \(label)")
    }

    /// `w-96` less the compact padding, so the rows truncate inside the `lg` popover.
    public override var intrinsicContentSize: NSSize { NSSize(width: 384 - 24, height: 8 + 20 + 4 + 20 + 4 + 16 + 8) }

    public override func layout() {
        super.layout()
        var y: CGFloat = 8
        for (row, height) in zip(rows, [20, 20, 16] as [CGFloat]) {
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
