# Fidelity at Nightly 5258

Written 2026-11-25 on the Mac mini M2 Pro (task repin-5258, branch `repin-5258`). `design/t3-source/main.css` is 5258's `client/assets/main-DY6PYWI3.css`, and 4928's stays as `main-4928.css`.

## Token changes from 4928

`scripts/extract-tokens --version v0.1.13-nightly.20261125.5258` with chrome-headless-shell 156.0.8078.70. No token changed value and none was removed. Every semantic color, radius, text size, shadow, easing, number and raw string resolves exactly as it did at 4928, so CandyWrapper's own frozen palettes and Redesign see no change.

Added:

- `--color-rose-300`, `#ffa1ad` in both themes.
- `--color-rose-700`, `#c60036`.
- `--color-sky-700`, `#0069a8`.
- `--color-violet-700`, `#7008e7`.
- `--html-preview-max-width`, `46rem`, as `Tokens.LengthRem.htmlPreviewMaxWidth`.

Tailwind emits a palette color only when a class uses it, so the four colors are new because 5258's Workflows run chips use them (`WorkflowRunFeed.tsx:139-143`). The Workflows chip view had a hand-converted copy of them, which now reads the extracted tokens.

Three new custom properties stay unresolved, like the other context-dependent ones: `--chat-lane-inset-end`, `--chat-lane-inset-start` and `--chat-timeline-gutter`.

## Component references

`scripts/component-reference` regenerated all 117 specs from the 5258 stylesheet. 106 PNGs changed, and none was committed:

- `math`, 100 PNGs. 5258 draws math as SVG from Words instead of KaTeX HTML (#27866, `0fb6ac6e65`, `apps/web/src/markdown/wordsHast.ts:873-901`, `index.css:2348-2355`). The math spec still holds 4928's KaTeX markup, so the regenerated PNGs showed 4928 markup under 5258's CSS, which T3 never draws. The math spec needs a generator that renders through Words, and CandyWrapper's math needs a port to match. Both notes files marked #27866 as having no visual change, and that is wrong for math.
- `switch` `default.mixed.focus-visible`, 2 PNGs, max channel delta 1, and `wide-tables`, 4 PNGs, one extra row of capture margin. Both are this Mac's capture noise that `nightly-4928-fidelity.md` already describes.

Every other PNG, including the ones recaptured from 5258 during the port, came out byte-identical.

## Fidelity run

`scripts/test --filter 'Fidelity|RedesignBaselineTests|RedesignTokenGuardTests'`: FeaturesTests 107 tests in 75 suites with 2 issues, DesignSystemTests 70 tests in 12 suites passed. `RedesignBaselineTests` and `RedesignTokenGuardTests` pass without re-recording. The only failure is `PanelScreensFidelityTests` `05-approval-request`, which failed the same way before this catch-up, so the re-pin exposed no visual change to port.

## The approval case

`05-approval-request` differs by 4.80% light and 4.89% dark against a 4% ceiling. Its cause is Chrome's text rasterizer against CoreText's, on the same Mac:

- The 4928 reference was captured on this Mac mini M2 Pro on 2026-11-19 (`design/reference-4928/README.md`), so no other machine is involved.
- A shift search over 160 px windows of each line finds no vertical offset and at most a quarter of a device pixel horizontally, with no drift along the line.
- The ink in each line matches within 0.2% for the command and 1.6% for the status row, and inked pixel counts within 1%.

The 4% ceiling dates from the 3824 reference (`8de8b79e`), where the command fit on one line and the case measured 3.22%. At 4928 the command wraps to two lines of monospace text, which doubles the glyph edges that the two rasterizers draw differently.

A 5258 recapture would not change this. For a command approval 5258 draws the same markup as 4928: `c4d0e05d96` (#42535) only adds the push hooks branch to `TimelinePendingApprovalRow.tsx`. The 5258 reference sandbox has no pending approval, because it expired when 5258 first started, so a recapture also needs a real turn. I made neither. Passing the case needs a decision from the user: a 5% ceiling for `approval`, or a shorter command in the fixture.

## Math

Written 2026-11-26 (task math-5258). #27866 (`0fb6ac6e65`) moved chat Markdown to Words, `@pierre/words` 0.2.2-t3.4 from T3's fork (`apps/web/deps/pierre-words-0.2.2-t3.4-7c04b7f1.tgz`, Apache 2.0). Words typesets TeX itself, in WebAssembly, and KaTeX is gone from chat. Only Mermaid labels still use KaTeX (`MermaidDiagram.tsx:47-67`), so `MermaidDiagrams.swift:269` stays as it is. `f9f34aab78` (#41361) only guards Words' start-up, and no later commit in the range touches math.

What 5258 draws:

- Each formula is an `<svg role="img" aria-label="<TeX>">` of `<text>` glyphs, `<rect>` rules and `<path>` shapes (`wordsHast.ts:323-369` keeps only those).
- The font is the system's STIX Two Math (`font-family: 'STIX Two Math','Cambria Math','Latin Modern Math',math,serif`), at 1.21em (`index.css:2352-2354`). Letters are Unicode math italics, not KaTeX's Computer Modern.
- Layout is Appendix G with STIX Two Math's MATH constants and its glyph metrics rounded to tens of units (Words' `src/math.wat`, `tables/math-metrics.txt`).
- Display big operators are the text glyph scaled 1.3, integrals 1.8. Radicals are a stroked polyline, and tall parentheses, brackets, braces, bars and angles are Words' own paths.
- Inline math is an `inline-block align-middle` span and display math a `block` span with `margin: 1em auto` on the SVG. Both scroll sideways with `max-w-full overflow-x-auto` (`wordsHast.ts:863-871`).
- Copying is unchanged: `\(tex\)` and `\[\ntex\n\]\n\n` from `data-markdown-copy` (`wordsHast.ts:877-889`).
- An unknown command draws in red (`#c00`), and an unclosed group closes itself. A formula Words can't lay out shows as code.

CandyWrapper's port, in `Features/Markdown/Math`:

1. `scripts/gen-math-spec` renders the corpus through that Words build, and the 156 math PNGs are recaptured from it.
2. `MathFont` uses the system STIX Two Math, so the bundled Latin Modern Math (717 KB, GUST license) and its notice are gone.
3. `MathTypesetter` follows Words for glyph metrics, script shifts, limits, big operators, radicals, `\left…\right` and delimiter shapes, and `\text` runs. `MathProbeTests.parity` with `CW_MATH_PARITY=1` compares every glyph and rule with Words' SVG. After the port, 36 of the 39 cases match to within 0.005em. The probe pairs glyphs one by one, so for the cases where Words draws a word as one `<text>` (`lim`, `det`, `mod`, `\text`) it checks the box.
4. Glyphs draw with Core Text and font smoothing on device rows at quarter-pixel x, as Skia draws Blink's SVG text.
5. VoiceOver reads a display formula as its TeX, as T3's `aria-label` gives it.

`MathFidelityTests` against the 5258 references: 33 of 152 cases over their ceilings with the 4928 port, 1 after this one. `10-inline-sum` light at 1x differed by 9.81% against 9.00%.

Two causes, found by comparing the ink of each glyph column in the reference and the render:

1. The references are clipped from the page at y values with a fraction (`15-energy` at 1416.640625), and the PNG starts at the nearest device row. Blink rounds each formula's baseline to a page device row, so a reference's baseline lands on row 27 or 28 depending on that fraction, while the test drew every formula at 27.5. `round(capture.y)` as the PNG's first row predicts the measured row of every inline case. The test now places the view at the capture's fraction of a device pixel (`metrics.json` has `capture.y`), and the formula snaps its baseline to a device row instead of half a point.
2. Filled outlines carry 15 to 18% less ink than Chromium's glyphs at 1x. Skia draws SVG text through Core Text at the device size with font smoothing, so math does the same, with each glyph's y on a device row and its x on a quarter pixel.

What didn't help: snapping the SVG box and scaling to its snapped size as `SVGRootPainter` does (mean 3.01%), Core Text without smoothing (no gain over outlines), subpixel quantizing by Core Text (3.08%), and smoothing off for light ink in dark mode (2.51%).

The same comparison found display formulas drawn 1em high, as the block left out the SVG's `margin: 1em auto`. The loose ceilings hid it. After all three fixes the mean is 2.09% where it was 4.09%, `10-inline-sum` light at 1x is 1.02%, and no ceiling changed. Dark still differs more than light (7.11% for `10-inline-sum` at 1x): Core Text spreads light ink on dark more than Skia's mask does, and no Core Graphics setting closes that.

Left:

- `cases` rows are 0.24em taller than Words', `\mathbb{R}^n` puts the exponent 0.07em lower, and accents sit 0.12em lower.
- An unknown command shows the formula as code, where Words draws the command in red.
- `\frac{a}{` shows as code, where Words draws a fraction with an empty denominator.
- An inline formula wider than the column is clipped, where T3 scrolls it.
