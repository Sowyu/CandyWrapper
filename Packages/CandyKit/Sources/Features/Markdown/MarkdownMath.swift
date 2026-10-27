import AppKit

/// How T3 places a formula in a message (MarkdownMath.tsx:20-58, index.css `.chat-markdown-math-display`):
/// an inline formula is an `inline-block align-middle` box with `px-0.5 py-0.75` around KaTeX's line box, and a display
/// formula a centered block with the same padding, `my-[0.65rem]`, that scrolls sideways when wider than the column.
@MainActor
enum MarkdownMathStyle {
    static let padX: CGFloat = 2
    static let padY: CGFloat = 3
    /// `[&::-webkit-scrollbar]:h-2`: the lane a too-wide display formula adds below its padding.
    static let scrollbar: CGFloat = 8
    /// KaTeX's strut around the baseline, in em of the formula: `.katex { line-height: 1.2 }` over KaTeX_Main's ascent and descent.
    static let strutAbove: CGFloat = 0.9
    static let strutBelow: CGFloat = 0.3

    /// Display formulas scroll with ids past every code block's, sharing the code blocks' scroll state and bar.
    static func scrollID(_ index: Int) -> Int { 1_000_000 + index }

    /// KaTeX's line box around the formula: its strut, or the formula where it reaches past it.
    static func content(_ layout: MathLayout, textSize: CGFloat) -> (above: CGFloat, below: CGFloat) {
        let em = textSize * MathRenderer.scale
        return (max(layout.height, strutAbove * em), max(layout.depth, strutBelow * em))
    }

    /// `vertical-align: middle`: the padded box's middle sits half the parent's x-height above its baseline. Returns how far
    /// the box reaches above and below the text baseline, and where the formula's baseline lands (positive is down).
    static func inline(_ layout: MathLayout, parent: NSFont, textSize: CGFloat) -> (above: CGFloat, below: CGFloat, baseline: CGFloat) {
        let (a, b) = content(layout, textSize: textSize)
        let half = (a + b) / 2 + padY, xh = parent.xHeight / 2
        return (half + xh, half - xh, -xh + (a - b) / 2)
    }

    static func inlineBoxes(_ inline: MarkdownStyle.Inline, parent: NSFont, textSize: CGFloat) -> [(index: Int, above: CGFloat, below: CGFloat)] {
        inline.formulas.map { f in
            let e = Self.inline(f.layout, parent: parent, textSize: textSize)
            return (f.range.location, e.above, e.below)
        }
    }

    static func items(_ inline: MarkdownStyle.Inline, in textBox: MarkdownTextBox, parent: NSFont, textSize: CGFloat, color: NSColor) -> [MarkdownLayout.Item] {
        inline.formulas.compactMap { f in
            guard let span = textBox.spans(f.range).first else { return nil }
            let e = Self.inline(f.layout, parent: parent, textSize: textSize)
            return .math(f.layout, CGPoint(x: span.x0 + padX, y: span.baseline + e.baseline), color)
        }
    }
}
