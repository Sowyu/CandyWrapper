import AppKit
import DesignSystem
import T3Store

/// `PushHooksApprovalDetails` (5258 chat/PushHooksApprovalDetails.tsx:6-24, #42535): the branch and hooks a push hooks
/// approval names, under its question. A `grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-xs text-muted-foreground`
/// list: the label in `text-foreground/80`, then a configured hook's name in `text-foreground` with `me-2`, then the code
/// in `font-mono text-foreground`, wrapping anywhere.
final class PushHooksApprovalDetailsView: DSView {
    private static let lineHeight: CGFloat = 16

    var rows: [PendingApproval.PushHooks.Row] = [] { didSet { if rows != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    private var labelWidth: CGFloat {
        rows.map { ceil(TextLine(NSAttributedString(string: $0.label, attributes: [.font: DSFont.ui(12)])).width) }.max() ?? 0
    }

    private func value(_ row: PendingApproval.PushHooks.Row) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let fg = Themed.color(\.foreground)
        if let name = row.name, !name.isEmpty {
            out.append(NSAttributedString(string: name, attributes: [.font: DSFont.ui(12), .foregroundColor: fg]))
            // `me-2`: 8pt before the code.
            out.append(NSAttributedString(string: " ", attributes: [.font: DSFont.ui(12), .kern: 8 - TextLine(NSAttributedString(string: " ", attributes: [.font: DSFont.ui(12)])).width]))
        }
        out.append(NSAttributedString(string: row.code, attributes: [.font: DSFont.mono(12), .foregroundColor: fg]))
        return out
    }

    private func layouts(width: CGFloat) -> [TextBlockLayout] {
        let valueWidth = max(1, width - labelWidth - 12)
        return rows.map { TextBlockLayout(value($0), width: valueWidth, lineHeight: Self.lineHeight) }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        return layouts(width: width).map { max(Self.lineHeight, $0.height) }.reduce(0, +) + CGFloat(rows.count - 1) * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lw = labelWidth
        var y: CGFloat = 0
        for (row, layout) in zip(rows, layouts(width: bounds.width)) {
            let label = TextBlockLayout(NSAttributedString(string: row.label, attributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.foreground, 0.8)]),
                                        width: lw + 1, lineHeight: Self.lineHeight)
            label.draw(in: ctx, origin: CGPoint(x: 0, y: y), width: lw + 1, alignment: .left)
            layout.draw(in: ctx, origin: CGPoint(x: lw + 12, y: y), width: bounds.width - lw - 12, alignment: .left)
            y += max(Self.lineHeight, layout.height) + 2
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
