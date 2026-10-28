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
    private var fullHead = ""
    private var fullTail = ""
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
    public static func split(_ value: String, tail: Int? = nil, classic: Bool = false) -> (head: String, tail: String)? {
        let chars = Array(value)
        var keep = tail ?? 10
        if tail == nil, let slash = chars.lastIndex(of: "/"), slash > 0, slash < chars.count - 1 {
            let segment = chars.count - slash - 1
            keep = segment <= 16 ? segment : 10
        }
        guard keep > 0, chars.count > keep + 4 else { return nil }
        var cut = chars.count - keep
        if !classic, tail == nil {
            let breaks: Set<Character> = ["-", "_", ".", "/"]
            if !breaks.contains(chars[cut - 1]) {
                let shorter = ((cut + 1)...max(cut + 1, chars.count - 4)).first { $0 <= chars.count - 4 && breaks.contains(chars[$0 - 1]) }
                let longer = stride(from: cut - 1, through: max(5, chars.count - 16), by: -1).first { breaks.contains(chars[$0 - 1]) }
                cut = shorter ?? longer ?? cut
            }
        }
        return (String(chars[..<cut]), String(chars[cut...]))
    }

    private func split() {
        let parts = Self.split(value, tail: tail, classic: DesignGeometry.usesClassic(self))
        fullHead = parts?.head ?? value
        fullTail = parts?.tail ?? ""
        head.text = fullHead
        tailLabel.text = fullTail
        toolTip = showsTitle ? value : nil
        setAccessibilityLabel(value)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(width(fullHead) + width(fullTail)), height: lineHeight)
    }

    private func width(_ text: String) -> CGFloat {
        TextLine(NSAttributedString(string: text, attributes: [.font: font])).width
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        split()
    }

    public override func layout() {
        super.layout()
        head.text = fullHead
        tailLabel.text = fullTail
        // middle-truncate.tsx:62-92: cut at a whole character and place the tail's ellipsis flush.
        if !DesignGeometry.usesClassic(self), !fullTail.isEmpty,
           width(fullHead) + width(fullTail) > bounds.width {
            let ellipsisTail = "…" + fullTail
            let available = max(0, bounds.width - width(ellipsisTail))
            let chars = Array(fullHead)
            var fits = 0, over = chars.count + 1
            while over - fits > 1 {
                let mid = (fits + over) / 2
                if width(String(chars.prefix(mid))) <= available { fits = mid } else { over = mid }
            }
            head.text = String(chars.prefix(fits))
            tailLabel.text = ellipsisTail
        }
        // The tail is `shrink-0`; the head takes what is left and truncates.
        let tailWidth = tailLabel.text.isEmpty ? 0 : min(tailLabel.textWidth, bounds.width)
        let headWidth = min(head.textWidth, bounds.width - tailWidth)
        head.frame = NSRect(x: 0, y: 0, width: max(0, headWidth), height: bounds.height)
        tailLabel.frame = NSRect(x: max(0, headWidth), y: 0, width: tailWidth, height: bounds.height)
    }
}
