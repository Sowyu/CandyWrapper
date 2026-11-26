import AppKit
import DesignSystem

/// The file header's "Open in" picker: `OpenInPicker` with `compact` in the toolbar look (5258
/// components/chat/OpenInPicker.tsx:254-361, FilePreviewPanel.tsx:1605-1619). A `Group` of an outline `xs`
/// button holding the preferred editor's icon, labelled "Open file in preferred editor", a `GroupSeparator`,
/// and an outline `icon-xs` chevron, "Choose editor". The owner fills the icon and the actions.
///
/// Redesign draws the two as ghost 28pt buttons joined edge to edge, as its other file header actions are.
public final class FileOpenInPicker: DSView {
    public let primary = ButtonView(nil, icon: .squareArrowOutUpRight, variant: .outline, size: .xs)
    public let chevron = ButtonView(nil, icon: .chevronDown, variant: .outline, size: .iconXs)
    private lazy var group = GroupView(buttons: [primary, chevron], separators: true)
    private var redesign: Bool?
    private var glyph: ImageGlyphView?

    /// A full-color editor mark (VS Code, the JetBrains IDEs) drawn over the primary part in place of its icon, which
    /// stays for the part's width.
    public var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            glyph?.removeFromSuperview()
            glyph = image.map(ImageGlyphView.init)
            if let glyph { primary.addSubview(glyph) }
            if image != nil { primary.icon = primary.icon ?? .squareArrowOutUpRight }
            primary.iconColor = image != nil ? .clear : iconColor
            needsLayout = true
        }
    }
    /// The primary icon's color when no image covers it.
    public var iconColor: NSColor? { didSet { if image == nil { primary.iconColor = iconColor } } }

    /// `aria-label` and tooltip of the primary part when `compact` (OpenInPicker.tsx:260).
    public static let primaryLabel = "Open file in preferred editor"
    public static let chevronLabel = "Choose editor"

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Open in editor")
        primary.iconSize = 14
        primary.setAccessibilityLabel(Self.primaryLabel)
        primary.setTooltip(Self.primaryLabel)
        // `ChevronDownIcon className="size-4"`.
        chevron.iconSize = 16
        chevron.setAccessibilityLabel(Self.chevronLabel)
        chevron.setTooltip(Self.chevronLabel)
        addSubview(group)
        applyLook()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { group.intrinsicContentSize }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    private func applyLook() {
        let dither = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        guard dither != redesign else { return }
        redesign = dither
        primary.variant = dither ? .ghost : .outline
        chevron.variant = dither ? .ghost : .outline
        primary.size = dither ? .iconSm : .xs
        chevron.size = dither ? .iconSm : .iconXs
        group.separators = !dither
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    public override func layout() {
        super.layout()
        let s = group.intrinsicContentSize
        group.frame = NSRect(x: 0, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
        group.layoutSubtreeIfNeeded()
        glyph?.frame = NSRect(x: ((primary.bounds.width - 14) / 2).rounded(), y: ((primary.bounds.height - 14) / 2).rounded(), width: 14, height: 14)
    }
}
