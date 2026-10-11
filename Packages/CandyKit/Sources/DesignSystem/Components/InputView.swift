import AppKit

/// T3's `Input` (`apps/web/src/components/ui/input.tsx`), desktop (`sm:`) values.
/// Spec: docs/research/recovered/ui-components-a.md section 3. DraftInput is this plus `onCommit`.
public final class InputView: FieldView {
    public enum Size: String, CaseIterable, Sendable {
        case sm, compact, `default`, lg
        /// An in-place editor the size of a line of text (`rounded-sm border px-1 text-sm`): the sidebar's rename field.
        case inline

        /// Height with border, inline padding, font px, radius.
        var metrics: (height: CGFloat, padding: CGFloat, font: CGFloat, radius: CGFloat) {
            switch self {
            case .sm: (28, 9, 14, 10)
            case .compact: (30, 9, 12, 8)
            case .default: (32, 11, 14, 10)
            case .lg: (36, 11, 14, 10)
            case .inline: (22, 4, 14, 4)
            }
        }
    }

    public enum Font: String, Sendable { case `default`, mono }
    /// `font-medium` and friends; regular by default.
    public var fontWeight: NSFont.Weight = .regular { didSet { configure() } }

    public var size: Size = .default { didSet { configure() } }
    public var fontStyle: Font = .default { didSet { configure() } }
    /// `unstyled`: no frame. InputGroup draws it instead.
    public var unstyled = false { didSet { dimsWhenDisabled = !unstyled; restyle(); invalidateIntrinsicContentSize() } }
    /// Extra inline padding InputGroup sets next to addons (`ps-2` / `pe-2`), replacing the size padding.
    public var paddingOverride: (leading: CGFloat?, trailing: CGFloat?) = (nil, nil) { didSet { needsLayout = true } }

    /// DraftInput: called with the value on Return or when focus leaves.
    public final var onCommit: (@MainActor (String) -> Void)?

    public convenience init(placeholder: String = "", text: String = "", size: Size = .default, font: Font = .default) {
        self.init(multiline: false)
        self.size = size
        self.fontStyle = font
        self.placeholder = placeholder
        self.text = text
        configure()
    }

    override init(multiline: Bool) {
        super.init(multiline: false)
        configure()
    }

    public override func fontRuntimeDidChange() {
        super.fontRuntimeDidChange()
        configure()
    }

    private func configure() {
        let m = size.metrics
        font = fontStyle == .mono ? DSFont.mono(m.font, weight: fontWeight) : DSFont.ui(m.font, weight: fontWeight)
        lineHeight = m.height - 2
        restyle()
        invalidateIntrinsicContentSize()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: unstyled ? size.metrics.height - 2 : size.metrics.height)
    }

    public override func layout() {
        super.layout()
        let m = size.metrics
        let border: CGFloat = unstyled ? 0 : 1
        let leading = paddingOverride.leading ?? m.padding
        let trailing = paddingOverride.trailing ?? m.padding
        placeEditor(in: NSRect(x: border + leading, y: border, width: max(0, bounds.width - 2 * border - leading - trailing),
                               height: lineHeight))
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if old.focused && !state.focused { onCommit?(text) }
    }

    override func restyle() {
        decoration.boxStyle = unstyled ? BoxStyle() : FieldStyles.frame(state: state, radius: size.metrics.radius)
        placeholderLabel.color = Themed.color(\.contrastPlaceholder)  // `placeholder:text-placeholder`
    }
}
