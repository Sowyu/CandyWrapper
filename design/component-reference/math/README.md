# Math reference captures

Capture-only fixtures from T3 Nightly 5258, where Words (`@pierre/words` 0.2.2-t3.4,
T3 #27866) draws each formula as an SVG of `<text>` glyphs in the system's STIX Two
Math, with T3's compiled `design/t3-source/main.css`. The app does not load these
scripts or the Words package.

Source, in the 5258 tree: `apps/web/src/markdown/wordsHast.ts:323-369` sanitizes the
SVG, `:858-892` wraps it in the span that copying reads, and `:1146-1152` sets Words'
options. `index.css:2348-2355` sets the SVG to 1.21em. `ChatMarkdown.tsx:2105-2112`
supplies the body classes, including 14px text and relaxed line height.

To regenerate, unpack the Words tarball T3 ships outside the repository, then run from
the repository root:

```sh
mkdir -p ~/CandyWrapper-research/tools/pierre-words-0.2.2-t3.4
tar xzf <t3code at 5258>/apps/web/deps/pierre-words-0.2.2-t3.4-7c04b7f1.tgz \
  -C ~/CandyWrapper-research/tools/pierre-words-0.2.2-t3.4
scripts/gen-math-spec
scripts/component-reference design/component-reference/math.json
```

`gen-math-spec` needs Node 18 or later. It renders each case with Words'
`renderToHtml(..., {math: true, texDelimiters: true})`, keeps only what
`sanitizeMath` keeps, and fails if Words emits anything else. The capture fails when
Chromium can't find STIX Two Math, which macOS ships.

There are 39 cases, each in light and dark at device scale 1 and 2, for 156 PNGs.
Filenames are `NN-short-name.rest.THEME.png` at 1x and
`NN-short-name.rest.THEME@2x.png` at 2x. Display and paragraph containers are 480
CSS px wide, with the capture tool's 8 CSS px padding around the case element.
Case 39 is `\frac{a}{`: Words closes the open group itself, so 5258 draws a
fraction with an empty denominator rather than the source.

`metrics.json` maps each PNG filename to an object:

- `scale` is the device scale, and `units` is `CSS px`.
- `capture` is the CDP clip rectangle in document CSS coordinates.
- `wrapper` is the size of `[data-markdown-math]`, without margins.
- `formula.width` is the SVG's width, and `formula.em` its font size.
- `formula.height` and `formula.depth` are Words' layout extent above and below the baseline, from the viewBox.
- `formula.baselineY` is the formula baseline's offset from the clip's top.
- `textBaselineY` and `formulaBaselineY` give the paragraph cases' two baselines.
- `background` is the computed body color.
