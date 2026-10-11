import AppKit
import DesignSystem
import T3Protocol

/// The stack menu's shared parts: `PullRequestStackHeader`, `PullRequestStackLayers` and
/// `PullRequestStackLayerContent` (PullRequestStackHeader.tsx, PullRequestStackLayers.tsx,
/// PullRequestStackLayerContent.tsx), as menu items.
@MainActor
public enum PullRequestStackMenu {
    /// "Stack #n", the notice ("May be stale" or "Refreshing…", the notice as its tooltip) and the
    /// retry item while the read failed.
    public static func header(number: Int, notice: String?, stale: Bool, onRetry: (@MainActor () -> Void)?) -> [MenuItem] {
        var items: [MenuItem] = [.label("Stack #\(number)")]
        if let notice {
            var n = MenuItem.label(stale ? "May be stale" : "Refreshing…")
            n.tooltip = notice
            items.append(n)
        }
        if stale, let onRetry {
            var retry = MenuItem("Retry stack refresh")
            retry.action = onRetry
            items.append(retry)
        }
        return items
    }

    /// The layers top first, each its state glyph, title and `#n · branch · State`, the open one
    /// checked; then `↳ base`.
    public static func layers(_ stack: PullRequestStackDetail, current: Int, pending: Bool, onSelect: (@MainActor (Int) -> Void)?) -> [MenuItem] {
        var items: [MenuItem] = stack.layers.reversed().map { layer in
            let lines = PullRequestWriteLogic.stackLayerLines(layer, compact: false)
            let tone = PullRequestStateTone(state: layer.state, isDraft: layer.isDraft ?? false)
            var item = MenuItem(lines.title, icon: PullRequestStyle.icon(tone), disabled: onSelect == nil || pending)
            item.iconColor = PullRequestStyle.color(tone)
            item.subtitle = lines.detail
            if layer.number == current { item.badge = IconName.check.definition }
            let number = layer.number
            item.action = { onSelect?(number) }
            return item
        }
        items.append(.label("↳ \(stack.base)"))
        return items
    }

    /// `PullRequestStackPopover`'s body before the read lands or after it found nothing (lines 36-44).
    public static func placeholder(number: Int, text: String) -> [MenuItem] {
        [.label("Stack #\(number)"), .label(text)]
    }
}

/// The confirmation's list (`max-h-48 space-y-1`): each layer compact in a `rounded-md bg-muted/50
/// px-3 py-2` row.
final class PullRequestStackLayerListView: DSView {
    private var rows: [(fill: CALayer, icon: IconView, title: LabelView, detail: LabelView)] = []

    init(_ layers: [PullRequestStackDetail.Layer]) {
        super.init(frame: .zero)
        rows = layers.map { layer in
            let lines = PullRequestWriteLogic.stackLayerLines(layer, compact: true)
            let tone = PullRequestStateTone(state: layer.state, isDraft: layer.isDraft ?? false)
            let fill = CALayer()
            fill.cornerRadius = 6
            fill.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer_?.addSublayer(fill)
            let icon = IconView(name: PullRequestStyle.icon(tone), size: 16, strokeColor: PullRequestStyle.color(tone))
            let title = LabelView(lines.title, font: DSFont.ui(14))
            title.lineHeight = 20
            let detail = LabelView(lines.detail, font: DSFont.ui(12))
            detail.lineHeight = 16
            [icon, title, detail].forEach(addSubview)
            return (fill, icon, title, detail)
        }
    }

    private var layer_: CALayer? { layer }
    private static let rowHeight: CGFloat = 8 + 36 + 8

    override var intrinsicContentSize: NSSize {
        let h = rows.isEmpty ? 0 : CGFloat(rows.count) * Self.rowHeight + CGFloat(rows.count - 1) * 4
        return NSSize(width: NSView.noIntrinsicMetric, height: min(192, h))
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        for (i, r) in rows.enumerated() {
            let y = CGFloat(i) * (Self.rowHeight + 4)
            r.fill.frame = CGRect(x: 0, y: y, width: w, height: Self.rowHeight)
            r.icon.frame = NSRect(x: 12, y: y + 18, width: 16, height: 16)
            r.title.frame = NSRect(x: 36, y: y + 8, width: max(0, w - 48), height: 20)
            r.detail.frame = NSRect(x: 36, y: y + 28, width: max(0, w - 48), height: 16)
        }
    }

    override func updateLayer() {
        for r in rows {
            r.fill.backgroundColor = Themed.color(\.muted, 0.5).cgColor(in: self)
            r.title.color = Themed.color(\.foreground)
            r.detail.color = Themed.color(\.mutedForeground)
        }
    }
}
