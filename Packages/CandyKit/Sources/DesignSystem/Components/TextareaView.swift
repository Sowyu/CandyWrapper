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

    func height(forWidth width: CGFloat) -> CGFloat {
        let m = size.metrics
        if width > 0, let container = editor.textContainer {
            container.size = NSSize(width: max(1, width - 2 - 2 * m.paddingX), height: .greatestFiniteMagnitude)
        }
        // TextKit adds the line spacing above every line but the first.
        let spacing = FieldEditor.lineMetrics(font: font, lineHeight: lineHeight).lineSpacing
        let content = max(lineHeight, editor.usedHeight + spacing)
        return min(Self.maxHeight, max(m.minHeight, content + 2 * m.paddingY)) + 2
    }

    public override func layout() {
        super.layout()
        let m = size.metrics
        let content = NSRect(x: 1 + m.paddingX, y: 1 + m.paddingY,
                             width: max(0, bounds.width - 2 - 2 * m.paddingX),
                             height: max(0, bounds.height - 2 - 2 * m.paddingY))
        placeEditor(in: content)
    }

    override func restyle() {
        decoration.boxStyle = FieldStyles.frame(state: state, radius: 10)
        // No placeholder class: preflight's `currentcolor` at 50%.
        placeholderLabel.color = Themed.color(\.contrastForeground, 0.5)
    }
}
