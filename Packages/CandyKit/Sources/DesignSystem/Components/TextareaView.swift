import AppKit

/// T3's `Textarea` (`apps/web/src/components/ui/textarea.tsx`), desktop values.
/// Grows with its content (`field-sizing: content`) from the size's minimum up to 256px, then scrolls.
/// Spec: docs/research/recovered/ui-components-a.md section 4.
public final class TextareaView: FieldView {
    public enum Size: String, CaseIterable, Sendable {
        case sm, `default`, lg

        /// Padding block, padding inline, min height of the textarea (border excluded).
        var metrics: (paddingY: CGFloat, paddingX: CGFloat, minHeight: CGFloat) {
            switch self {
            case .sm: (3, 9, 66)
            case .default: (5, 11, 70)
            case .lg: (7, 11, 74)
            }
        }
    }

    static let maxHeight: CGFloat = 256  // `max-h-64` on the textarea

    public var size: Size = .default { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    /// A plain `<textarea>` without the field frame: `block min-h-16 max-h-40 bg-transparent px-1 py-1.5
    /// text-sm outline-none placeholder:text-muted-foreground` (AssistantCitationCommentEditor.tsx:51).
    public var bare = false { didSet { restyle(); invalidateIntrinsicContentSize(); needsLayout = true } }
    /// A bare textarea's minimum height in place of `min-h-16`, such as one line for a chat field.
    public var bareMinHeight: CGFloat? { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }

    /// Padding block, padding inline, min and max height (border included).
    private var box: (paddingY: CGFloat, paddingX: CGFloat, minHeight: CGFloat, maxHeight: CGFloat, border: CGFloat) {
        if bare { return (6, 4, bareMinHeight ?? 64, 160, 0) }
        let m = size.metrics
        return (m.paddingY, m.paddingX, m.minHeight + 2, Self.maxHeight + 2, 1)
    }

    public convenience init(placeholder: String = "", text: String = "", size: Size = .default) {
        self.init(multiline: true)
        self.size = size
        self.placeholder = placeholder
        self.text = text
    }

    override init(multiline: Bool) {
        super.init(multiline: true)
        font = DSFont.ui(14)
        lineHeight = 20
        restyle()
    }

    /// Height with the 1px border; width is whatever the layout gives (`w-full`).
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        let m = box
        if width > 0, let container = editor.textContainer {
            container.size = NSSize(width: max(1, width - 2 * m.border - 2 * m.paddingX), height: .greatestFiniteMagnitude)
        }
        // TextKit adds the line spacing above every line but the first.
        let spacing = FieldEditor.lineMetrics(font: font, lineHeight: lineHeight).lineSpacing
        let content = max(lineHeight, editor.usedHeight + spacing)
        return min(m.maxHeight, max(m.minHeight, content + 2 * m.paddingY + 2 * m.border))
    }

    public override func layout() {
        super.layout()
        let m = box
        let content = NSRect(x: m.border + m.paddingX, y: m.border + m.paddingY,
                             width: max(0, bounds.width - 2 * m.border - 2 * m.paddingX),
                             height: max(0, bounds.height - 2 * m.border - 2 * m.paddingY))
        placeEditor(in: content, trailingPadding: m.paddingX)
    }

    override func restyle() {
        if bare {
            decoration.boxStyle = BoxStyle()
            placeholderLabel.color = Themed.color(\.mutedForeground)
            return
        }
        decoration.boxStyle = FieldStyles.frame(state: state, radius: 10)
        // No placeholder class: preflight's `currentcolor` at 50%.
        placeholderLabel.color = Themed.color(\.contrastForeground, 0.5)
    }
}
