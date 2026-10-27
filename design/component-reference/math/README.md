# Math reference captures

Capture-only fixtures from KaTeX 0.16.47 with T3's compiled `design/t3-source/main.css`.
The app does not load these scripts, stylesheets or fonts.

Source: `apps/web/src/components/chat/MarkdownMath.tsx:17-57` supplies all three
wrapper spans and the fallback. `MathTypeset.tsx:17-25,39` supplies KaTeX's exact
options and the extra typeset span. `ChatMarkdown.tsx:1591-1593` supplies body
classes, including 14px text and relaxed line height. Paths refer to the research
T3 checkout at the repository's `T3_VERSION`.

To regenerate, install the external dependency, then run from the repository root:

```sh
PATH="$HOME/CandyWrapper-research/tools/node-v24.22.1-darwin-arm64/bin:$PATH" \
  npm install --prefix "$HOME/CandyWrapper-research/tools/katex-0.16.47" \
  --no-audit --no-fund katex@0.16.47
scripts/gen-math-spec
scripts/component-reference design/component-reference/math.json
```

The stylesheet stays beside its fonts outside the repository. The capture tool
expands the spec's `~/` stylesheet path and waits for `document.fonts.ready`.
Measurements fail if KaTeX fonts are absent or any formula metric is nonfinite.

There are 39 cases, each in light and dark at device scale 1 and 2, for 156 PNGs.
Filenames are `NN-short-name.rest.THEME.png` at 1x and
`NN-short-name.rest.THEME@2x.png` at 2x. Display and paragraph containers are
480 CSS px wide. Each capture uses the existing tool's 8 CSS px padding around
the case element. Standalone cases capture the `.chat-markdown` root containing
one math wrapper; paragraph cases capture that root containing one `<p>`.

`manifest.json` retains the tool's existing case-name to CSS size map. For
paragraphs, that size describes the paragraph container, rather than the math.
`metrics.json` maps each complete PNG filename to an object:

- `scale`: device scale, 1 or 2. `units`: `CSS px`.
- `capture`: the CDP clip rectangle in document CSS coordinates, before scaling.
- `wrapper`: width and height of `[data-markdown-math]`, excluding margins.
- `formula.width`: the `.katex-html` bounding box width. Display boxes fill the
  available width; `formula.contentWidth` is the union of their top-level `.base`
  boxes and measures the centered equation itself.
- `formula.height` and `formula.depth`: TeX layout extent above and below the
  formula baseline. These come from the top-level `.base > .strut` CSS heights
  and vertical offsets, rather than the font's inline bounding box. They are
  layout metrics, not the visible glyph ink bounds.
- `formula.baselineY`: formula baseline offset from the clip's top, in CSS px.
  `formula.baselinePixelY` is the same offset multiplied by `scale`.
- `textBaselineY` and `formulaBaselineY`: paragraph text and formula baseline
  offsets from the clip's top in CSS px. Multiply by `scale` for PNG coordinates.
- `fallbackBaselineY`: the fallback source text's baseline; no `formula` object
  exists for case 39.
- `background`: computed body color. `loadedKatexFonts`: loaded KaTeX font faces
  for the entire corpus page, recorded as family, style and weight.

Baseline probes are zero-area inline-blocks aligned to the baseline inside the
measured element. The tool removes each probe before continuing. KaTeX's math
baseline and T3's surrounding text baseline can differ because the outer inline
wrapper uses `align-middle`.

Validation: inspected both scales and themes, inline and display equations,
matrices, running paragraphs and fallback source. No clipping or fallback fonts
appeared. All 156 PNG dimensions agree with the clip and scale within raster
rounding; metrics are finite, formula extents fit inside their clips, and CSS
metrics agree at both scales. Background RGB matches badge references: 252 in
light and 10 in dark for each channel. Recapturing `badge.json` before and after
the tool change left its tracked PNGs and manifest unchanged. App tests were not
run: preflight reported 36 GB free, below its 40 GB build threshold.
