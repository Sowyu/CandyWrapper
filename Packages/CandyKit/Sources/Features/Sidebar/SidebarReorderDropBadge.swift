import AppKit
import DesignSystem
import T3Store

/// `dropVerbBadge` on the lifted row (Sidebar.tsx:1071-1100, 1631-1640): `h-5 gap-1 rounded-sm border
/// border-primary/40 bg-primary/10 px-1.5 text-2xs font-medium text-primary`, a `size-3` icon and the verb.
public final class SidebarReorderDropBadge: DSView {
    private var icon = IconView(name: .pin, size: 12)
    private let label = LabelView("", font: DSFont.ui(11, weight: .medium))

    var verb: SidebarDropVerb = .pin {
        didSet {
            guard verb != oldValue else { return }
            icon.removeFromSuperview()
            icon = IconView(name: Self.icon(verb), size: 12)
            addSubview(icon)
            label.text = verb.title
            updateLayer()
            needsLayout = true
        }
    }

    public override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        label.text = verb.title
        label.lineHeight = 16
        addSubview(icon)
        addSubview(label)
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
    }

    /// The same icons as the row actions and the context menu, so the drop reads as the action it does.
    static func icon(_ verb: SidebarDropVerb) -> IconName {
        switch verb {
        case .pin: .pin
        case .unpin: .pinOff
        case .settle: .circleCheck
        case .unsettle: .undo2
        case .wake: .alarmClockOff
        }
    }

    /// 1 + 6 + 12 + 4 + text + 6 + 1.
    var preferredWidth: CGFloat { ceil(30 + label.textWidth) }

    public static func verb(from: SidebarSection?, to: SidebarSection) -> String? {
        from.flatMap { SidebarDropVerb.resolve(from: $0, to: to)?.title }
    }

    public override func layout() {
        super.layout()
        icon.frame = NSRect(x: 7, y: 4, width: 12, height: 12)
        label.frame = NSRect(x: 23, y: 2, width: max(0, bounds.width - 30), height: 16)
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.primary, 0.1).cgColor(in: self)
        layer?.borderColor = Themed.color(\.primary, 0.4).cgColor(in: self)
        icon.strokeColor = Themed.color(\.primary)
        label.color = Themed.color(\.primary)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
