# Math in messages

T3 3473 typesets TeX in messages when Settings > Appearance > Render math is on (T3 #18735, off by default). Up to 4928 it used KaTeX. From 5258 (#27866) Words, T3's WebAssembly Markdown renderer, draws each formula as an SVG of `<text>` glyphs in the system's STIX Two Math, with drawn radicals and grown delimiters.
CandyWrapper lays formulas out natively, without a web view. The user chose that on 2026-10-27.

## How it works

1. `MarkdownMathScanner.swift` finds formulas the way T3's `remark-math` with `micromark-extension-llm-math` and T3's patch does (`shared/src/markdownMath.ts`). It hides each one from Foundation's Markdown parser behind a placeholder and maps it back to `InlineRun.math` or `MarkdownBlock.math`. It runs only while Render math is on.
2. `Math/TeXParser.swift` parses the TeX into atoms. Anything outside stage 1 throws.
3. `Math/MathTypesetter.swift` lays the atoms out as Words' `src/math.wat` does: Appendix G with STIX Two Math's MATH constants, glyph metrics rounded to tens of units, big operators as the base glyph scaled 1.3 (1.8 for integrals) in display style, and radicals and tall delimiters as Words' own paths.
4. `MarkdownMath.swift` and `MarkdownLayout.displayMath` place formulas as T3's `wordsHast.ts` wrapper does. An inline formula is an `align-middle` box with 2px by 3px padding around the message's own line, and the line grows around a tall one. A display formula is centered and scrolls sideways when it is wider than the column.
5. `MathRenderer` caches up to 1,000 layouts by source, style and text size, like T3's typeset cache.

Glyphs are STIX Two Math, which macOS ships, so no font is bundled. They draw with Core Text and font smoothing at their device size, as Skia draws Blink's SVG text. The formula's baseline and each glyph's y sit on device rows and each glyph's x on a quarter pixel, where Blink and Skia put them. A display formula's SVG has `margin: 1em auto`, so the block holds an em above and below the formula.

Copying a selection puts each formula's TeX on the pasteboard as `\(…\)` or `\[…\]`, as T3's `data-markdown-copy` does. Find matches the TeX.

## Stage 1 supports

- `$…$`, `$$…$$`, `\(…\)`, `\[…\]` and closed `math` fences, with T3's rules for dollar amounts, escapes, code, links, citations and tables.
- Fractions (`\frac`, `\dfrac`, `\tfrac`, `\cfrac`), binomials, roots with an index.
- Sub- and superscripts, primes, `\limits` and `\nolimits`.
- Big operators (`\sum`, `\prod`, `\int`, `\oint`, `\bigcup` and kin) with limits in display style, and named operators (`\lim`, `\max`, `\sin`, `\operatorname`).
- Greek letters, about 250 symbols, `\not`, arrows, `\implies` and `\iff`.
- `\left…\middle…\right`, `\big` to `\Bigg`.
- `matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`, `Vmatrix`, `smallmatrix`, `cases`, `dcases`, `rcases`, `aligned`, `align`, `alignedat`, `split`, `gathered`, `array` with `l`, `c` and `r` columns, `equation`, `\substack` and `\\[dim]` row gaps.
- `\text` and its variants, `\mathrm`, `\mathbf`, `\mathit`, `\mathbb`, `\mathcal`, `\mathfrak`, `\mathsf`, `\mathtt` and `\boldsymbol`.
- Accents, including `\widehat`, `\widetilde` and the over-arrows, plus `\overline`, `\underline`, `\overbrace`, `\underbrace`, `\overset`, `\underset` and `\stackrel`.
- Spacing commands and `\hspace` in em, ex, pt and mu, plus `\phantom` and `\boxed`.
- `\color` and `\textcolor` with CSS names or hex, `\cancel`, `\bcancel` and `\xcancel`, `\xrightarrow` and its kin, `\hline` and `|` in `array`, and `\tag` in display math.

A formula stage 1 can't typeset shows its TeX as inline code. That is the user's choice, and 5258's Words also shows a formula it can't lay out as code. Like Words, an unknown command draws as its name in upright text in red (`#c00` in T3's themes, Redesign's destructive ink in Redesign), and an unclosed group or a missing argument closes itself, so `\frac{a}{` is a fraction with an empty denominator. Words draws the unknown command gray (`#888`) while its block still streams. CandyWrapper always draws it red.

## Next

- The `equation` environment's automatic number.
- Doubled rules in `array` (`||`, `\hline\hline`) draw as one line, and `\right` doesn't take a `\color` switched on inside `\left…\right`.
- `\\` line breaks at the top level of a display formula.
- An inline formula wider than the column scrolls sideways in T3; here it is clipped at the column's edge.
- Math kerning (cut-ins) and KaTeX's per-glyph metrics for script attachment.
- Citing a selection captures a formula as a space.
- An unclosed `math` fence stays code after streaming ends, where T3 renders it.

## Tests

- `MarkdownMathParserTests` mirrors T3's `markdownMath.test.ts`.
- `MathFidelityTests` compares 38 cases at 1x and 2x in light and dark against Words 0.2.2-t3.4 renders with T3's stylesheet (`scripts/gen-math-spec`, `design/component-reference/math`).
- `MathTypesetterTests` covers the fallback, copy and hostile input.
- `CW_MATH_PROBE=/tmp/x.png scripts/test --filter MathProbeTests` draws the corpus on one sheet, and `CW_MATH_PARITY=1` prints every glyph and rule that sits more than 0.005em from Words'.
