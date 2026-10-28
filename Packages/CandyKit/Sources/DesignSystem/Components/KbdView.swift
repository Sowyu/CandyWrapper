import AppKit

/// T3's `Kbd` (`apps/web/src/components/ui/kbd.tsx`): a 20px key cap on `foreground/7`.
/// Spec: docs/research/recovered/ui-components-a.md section 8.
public final class KbdView: DSView {
    public var keys: String { didSet { label.text = keys; invalidateIntrinsicContentSize() } }
    public var icon: IconName? { didSet { updateIcon() } }
    /// `rounded` (4px); InputGroup addons use 5px.
    public var radius: CGFloat = 4 { didSet { needsDisplay = true } }
    /// Overrides for parents that restyle keys, such as the command footer (`bg-foreground/8 text-foreground`).
    public var fillOverride: NSColor? { didSet { needsDisplay = true } }
    public var textOverride: NSColor? { didSet { applyColors() } }
    /// Off inside glass popups, whose text Chromium draws without subpixel smoothing.
    public var smoothsFont: Bool {
        get { label.smoothsFont }
        set { label.smoothsFont = newValue }
    }

    private let label = LabelView()
    private var iconView: IconView?

    public init(_ keys: String = "", icon: IconName? = nil) {
        self.keys = keys
        super.init(frame: .zero)
        label.text = keys
        label.font = DSFont.ui(12, weight: .medium)
        label.lineHeight = 16
        label.truncates = false
        addSubview(label)
        self.icon = icon
        updateIcon()
        applyColors()
    }

    public override var intrinsicContentSize: NSSize {
        // `min-w-5 px-1`; content is the text advance or a 12px icon (`gap-1` between them).
        var content = keys.isEmpty ? 0 : label.textWidth
        if iconView != nil { content += 12 + (keys.isEmpty ? 0 : 4) }
        return NSSize(width: max(20, content + 8), height: 20)
    }

    public override func layout() {
        super.layout()
        let textWidth = keys.isEmpty ? 0 : label.textWidth
        let content = textWidth + (iconView != nil ? 12 + (keys.isEmpty ? 0 : 4) : 0)
        var x = (bounds.width - content) / 2
        if let iconView {
            iconView.frame = NSRect(x: x, y: (bounds.height - 12) / 2, width: 12, height: 12)
            x += 16
        }
        label.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: textWidth, height: 16)
    }

    public override func updateLayer() {
        layer?.backgroundColor = (fillOverride ?? (DesignGeometry.usesClassic(self) ? Themed.color(\.muted) : Themed.color(\.contrastForeground, 0.07))).cgColor(in: self)
        layer?.cornerRadius = radius
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        label.color = textOverride ?? Themed.color(\.contrastMutedForeground)
        iconView?.strokeColor = textOverride ?? Themed.color(\.contrastMutedForeground)
    }

    private func updateIcon() {
        iconView?.removeFromSuperview()
        iconView = icon.map { IconView(name: $0, size: 12, strokeColor: textOverride ?? Themed.color(\.contrastMutedForeground)) }
        if let iconView { addSubview(iconView) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

/// T3's `KbdGroup`: keys in a row, 4px apart.
public final class KbdGroupView: DSView {
    public let keys: [KbdView]

    public init(_ keys: [KbdView]) {
        self.keys = keys
        super.init(frame: .zero)
        keys.forEach(addSubview)
    }

    public convenience init(keys: [String]) { self.init(keys.map { KbdView($0) }) }

    public override var intrinsicContentSize: NSSize {
        let widths = keys.map(\.intrinsicContentSize.width)
        return NSSize(width: widths.reduce(0, +) + 4 * CGFloat(max(0, keys.count - 1)), height: 20)
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 0
        for key in keys {
            let size = key.intrinsicContentSize
            key.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + 4
        }
    }
}
