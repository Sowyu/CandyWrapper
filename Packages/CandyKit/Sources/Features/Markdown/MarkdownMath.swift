import AppKit
import DesignSystem

/// How T3 places a formula in a message (MarkdownMath.tsx:20-58, index.css `.chat-markdown-math-display`):
/// an inline formula is an `inline-block align-middle` box with `px-0.5 py-0.75` around KaTeX's line box, and a display
/// formula a centered block with the same padding, `my-[0.65rem]`, that scrolls sideways when wider than the column.
@MainActor
enum MarkdownMathStyle {
    static let padX: CGFloat = 2
    static let padY: CGFloat = 3
    /// `[&::-webkit-scrollbar]:h-2`: the lane a too-wide display formula adds below its padding.
    static let scrollbar: CGFloat = 8

    /// Display formulas scroll with ids past every code block's, sharing the code blocks' scroll state and bar.
    static func scrollID(_ index: Int) -> Int { 1_000_000 + index }

    /// The wrapper's line box: the message's own line (its font at its line height, as the block inherits
    /// `.chat-markdown`'s line-height), grown where the formula reaches past it. Measured on T3 3669: every small inline
    /// formula's wrapper is 28.8px, 6px of padding around the 22.75px line (design/component-reference/math/metrics.json).
    static func content(_ layout: MathLayout, parent: NSFont, lineHeight: CGFloat) -> (above: CGFloat, below: CGFloat) {
        let strut = TextLine(NSAttributedString(string: " ", attributes: [.font: parent])).baseline(top: 0, lineHeight: lineHeight)
        return (max(layout.height, strut), max(layout.depth, lineHeight - strut))
    }

    /// `vertical-align: middle`: the padded box's middle sits half the parent's x-height above its baseline. Returns how far
    /// the box reaches above and below the text baseline, and where the formula's baseline lands (positive is down).
    static func inline(_ layout: MathLayout, parent: NSFont, lineHeight: CGFloat) -> (above: CGFloat, below: CGFloat, baseline: CGFloat) {
        let (a, b) = content(layout, parent: parent, lineHeight: lineHeight)
        let half = (a + b) / 2 + padY, xh = parent.xHeight / 2
        return (half + xh, half - xh, -xh + (a - b) / 2)
    }

    static func inlineBoxes(_ inline: MarkdownStyle.Inline, parent: NSFont, lineHeight: CGFloat) -> [(index: Int, above: CGFloat, below: CGFloat)] {
        inline.formulas.map { f in
            let e = Self.inline(f.layout, parent: parent, lineHeight: lineHeight)
            return (f.range.location, e.above, e.below)
        }
    }

    /// Each formula's draw item. A formula wider than the column is clipped to its placeholder (`max-w-full overflow-x-auto`).
    // ponytail: clipped, where T3 scrolls it sideways; give inline formulas scroll ids if long inline formulas show up
    static func items(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, parent: NSFont, color: NSColor) -> [MarkdownLayout.Item] {
        var out: [MarkdownLayout.Item] = []
        for f in inline.formulas {
            guard let span = textBox.spans(f.range).first else { continue }
            let e = Self.inline(f.layout, parent: parent, lineHeight: textBox.lineHeight)
            let item = MarkdownLayout.Item.math(f.layout, CGPoint(x: span.x0 + padX, y: span.baseline + e.baseline), color)
            guard f.layout.width + 2 * padX > span.x1 - span.x0 + 0.5 else { out.append(item); continue }
            out += [.clip(CGRect(x: span.x0, y: span.baseline - e.above, width: span.x1 - span.x0, height: e.above + e.below)), item, .endClip]
        }
        return out
    }
}
