import AppKit
import DesignSystem
import T3Store

/// Sidebar.logic.ts:265-276 and Sidebar.tsx:5297. The verb follows the destination lifecycle.
public final class SidebarReorderDropBadge: DSView {
    private let label = BadgeView("", variant: .secondary)
    public var title = "" { didSet { label.title = title; label.isHidden = title.isEmpty } }
    public override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        addSubview(label)
    }
    public static func verb(from: SidebarSection?, to: SidebarSection) -> String? {
        guard let from, from != to, to != .working, to != .snoozed else { return nil }
        if to == .pinned { return "Pin" }
        if to == .settled { return "Settle" }
        if from == .pinned { return "Unpin" }
        if from == .settled { return "Un-settle" }
        return "Wake"
    }
    public override func layout() {
        super.layout()
        label.frame = NSRect(x: max(0, bounds.width - label.intrinsicContentSize.width), y: 0, width: label.intrinsicContentSize.width, height: 24)
    }
    public override var wantsUpdateLayer: Bool { false }
    public override func draw(_ dirtyRect: NSRect) {
        Themed.color(\.primary).setFill()
        NSRect(x: 0, y: 11, width: bounds.width, height: 2).fill()
    }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
