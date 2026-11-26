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
