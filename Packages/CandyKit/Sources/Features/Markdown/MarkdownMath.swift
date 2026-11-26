import AppKit
import DesignSystem

/// How T3 places a formula in a message (wordsHast.ts:858-892 and index.css:2348-2355 at 5258): an inline formula is
/// an `inline-block align-middle` box with `px-0.5 py-0.75` around its SVG, and a display formula a centered block with
/// the same padding that scrolls sideways when wider than the column.
enum MarkdownMathStyle {
    static let padX: CGFloat = 2
    static let padY: CGFloat = 3
    /// `[&::-webkit-scrollbar]:h-2`: the lane a too-wide display formula adds below its padding.
    static let scrollbar: CGFloat = 8

    /// Display formulas scroll with ids past every code block's, sharing the code blocks' scroll state and bar.
    static func scrollID(_ index: Int) -> Int { 1_000_000 + index }
    /// Inline formulas scroll with ids from here, numbered in item order once the layout is done (`numberInlineScrolls`).
    static let inlineScrollBase = 2_000_000
    static func isInlineScroll(_ id: Int) -> Bool { id >= inlineScrollBase }

    /// Gives each inline formula's scroller its own id, counting from `inlineScrollBase` in item order.
    static func numberInlineScrolls(_ items: [MarkdownLayout.Item]) -> [MarkdownLayout.Item] {
        var next = inlineScrollBase
        return items.map {
            guard case .scroll(let id, let viewport, let width) = $0, isInlineScroll(id) else { return $0 }
            defer { next += 1 }
            return .scroll(codeIndex: next, viewport: viewport, contentWidth: width)
        }
    }

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

    /// Each formula's draw item. A formula wider than the column scrolls sideways inside its placeholder
    /// (`max-w-full overflow-x-auto`). T3 styles no scrollbar there, so macOS shows its overlay bar only while scrolling;
    /// CandyWrapper draws none and reserves no lane.
    static func items(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, parent: NSFont, color: NSColor) -> [MarkdownLayout.Item] {
        var out: [MarkdownLayout.Item] = []
        for f in inline.formulas {
            guard let span = textBox.spans(f.range).first else { continue }
            let e = Self.inline(f.layout, parent: parent, lineHeight: textBox.lineHeight)
            let contentWidth = f.layout.width + 2 * padX
            let wide = contentWidth > span.x1 - span.x0 + 0.5
            let item = MarkdownLayout.Item.math(f.layout, CGPoint(x: span.x0 + padX, y: span.baseline + e.baseline), color, clip: nil)
            guard wide else { out.append(item); continue }
            let viewport = CGRect(x: span.x0, y: span.baseline - e.above, width: span.x1 - span.x0, height: e.above + e.below)
            out += [.scroll(codeIndex: inlineScrollBase, viewport: viewport, contentWidth: contentWidth), item, .endClip]
        }
        return out
    }
}
