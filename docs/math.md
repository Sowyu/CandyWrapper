# Math in messages

T3 3473 typesets TeX in messages with KaTeX when Settings > Appearance > Render math is on (T3 #18735, off by default).
CandyWrapper lays formulas out natively, without a web view. The user chose that on 2026-10-27.

## How it works

1. `MarkdownMathScanner.swift` finds formulas the way T3's `remark-math` with `micromark-extension-llm-math` and T3's patch does (`shared/src/markdownMath.ts`). It hides each one from Foundation's Markdown parser behind a placeholder and maps it back to `InlineRun.math` or `MarkdownBlock.math`. It runs only while Render math is on.
2. `Math/TeXParser.swift` parses the TeX into atoms. Anything outside stage 1 throws.
3. `Math/MathTypesetter.swift` lays the atoms out with the TeXbook's Appendix G rules. It reads Latin Modern Math's OpenType MATH table for most constants, and uses KaTeX's Computer Modern values where KaTeX departs from the table: script shifts, limit spacing, the null delimiter and operator widths.
4. `MarkdownMath.swift` and `MarkdownLayout.displayMath` place formulas as T3's `MarkdownMath.tsx` does. An inline formula is an `align-middle` box with 2px by 3px padding around the message's own line, and the line grows around a tall one. A display formula is centered and scrolls sideways when it is wider than the column.
5. `MathRenderer` caches up to 1,000 layouts by source, style and text size, like T3's typeset cache.

Latin Modern Math (GUST Font License, listed in Settings > Licenses) is bundled because it is Computer Modern, the face KaTeX draws. STIX Two Math, which ships with macOS, stands in if the bundle lacks it.

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

A formula stage 1 can't typeset shows its TeX as inline code. That is the user's choice; T3 shows unparsable TeX as plain text.

## Next

- The `equation` environment's automatic number.
- `\\` line breaks at the top level of a display formula.
- An inline formula wider than the column scrolls sideways in T3; here it is clipped at the column's edge.
- Math kerning (cut-ins) and KaTeX's per-glyph metrics for script attachment.
- Citing a selection captures a formula as a space.
- An unclosed `math` fence stays code after streaming ends, where T3 renders it.

## Tests

- `MarkdownMathParserTests` mirrors T3's `markdownMath.test.ts`.
- `MathFidelityTests` compares 38 cases at 1x and 2x in light and dark against KaTeX 0.16.47 renders with T3's stylesheet (`scripts/gen-math-spec`, `design/component-reference/math`).
- `MathTypesetterTests` covers the fallback, copy and hostile input.
- `CW_MATH_PROBE=/tmp/x.png scripts/test --filter MathProbeTests` draws the corpus on one sheet, and `CW_MATH_METRICS=1` prints each box next to KaTeX's.
