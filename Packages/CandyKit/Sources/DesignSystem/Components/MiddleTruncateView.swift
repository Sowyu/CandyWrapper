import AppKit

/// T3's `MiddleTruncate` (`apps/web/src/components/ui/middle-truncate.tsx`): a head that truncates with an
/// end ellipsis and a tail that never shrinks, so paths keep their file name and branches their date.
/// Spec: docs/research/recovered/ui-components-b.md section 23.
public final class MiddleTruncateView: DSView {
    public var value: String { didSet { split() } }
    /// Characters kept at the end. nil: the last path segment if it is 16 or fewer, else 10.
    public var tail: Int? { didSet { split() } }
    public var font: NSFont { didSet { head.font = font; tailLabel.font = font; invalidateIntrinsicContentSize() } }
    public var color: NSColor = Themed.color(\.contrastForeground) { didSet { head.color = color; tailLabel.color = color } }
    public var lineHeight: CGFloat = 20 { didSet { head.lineHeight = lineHeight; tailLabel.lineHeight = lineHeight } }
    /// The full value as the hover tooltip (`title`), unless a tooltip already carries it.
    public var showsTitle = true { didSet { toolTip = showsTitle ? value : nil } }

    private let head = LabelView()
    private let tailLabel = LabelView()

    public init(_ value: String, font: NSFont = DSFont.ui(14), tail: Int? = nil) {
        self.value = value
        self.font = font
        self.tail = tail
        super.init(frame: .zero)
        for label in [head, tailLabel] {
            label.font = font
            label.lineHeight = lineHeight
            label.color = color
            addSubview(label)
        }
        tailLabel.truncates = false
        split()
    }

    /// `splitForMiddleTruncate`: code points (Swift Characters are grapheme clusters, which also never split an emoji).
    public static func split(_ value: String, tail: Int? = nil) -> (head: String, tail: String)? {
        let chars = Array(value)
        var keep = tail ?? 10
        if tail == nil, let slash = chars.lastIndex(of: "/"), slash > 0, slash < chars.count - 1 {
            let segment = chars.count - slash - 1
            keep = segment <= 16 ? segment : 10
        }
        guard keep > 0, chars.count > keep + 4 else { return nil }
        return (String(chars[..<(chars.count - keep)]), String(chars[(chars.count - keep)...]))
    }

    private func split() {
        let parts = Self.split(value, tail: tail)
        head.text = parts?.head ?? value
        tailLabel.text = parts?.tail ?? ""
        toolTip = showsTitle ? value : nil
        setAccessibilityLabel(value)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(head.textWidth + (tailLabel.text.isEmpty ? 0 : tailLabel.textWidth)), height: lineHeight)
    }

    public override func layout() {
        super.layout()
        // The tail is `shrink-0`; the head takes what is left and truncates.
        let tailWidth = tailLabel.text.isEmpty ? 0 : min(tailLabel.textWidth, bounds.width)
        let headWidth = min(head.textWidth, bounds.width - tailWidth)
        head.frame = NSRect(x: 0, y: 0, width: max(0, headWidth), height: bounds.height)
        tailLabel.frame = NSRect(x: max(0, headWidth), y: 0, width: tailWidth, height: bounds.height)
    }
}
