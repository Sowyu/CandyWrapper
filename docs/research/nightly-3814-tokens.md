# Nightly 3814 design tokens

The design input moves from v0.1.3-nightly.20261025.3669 (`main-Bi2TGrCG.css`) to v0.1.4-nightly.20261028.3814 (`main-Bp5xFxkG.css`). `T3_VERSION` and the server-skew client version stay on 3669 until the later pin task. The previous stylesheet is `design/t3-source/main-3669.css`.

## Changed tokens

The compiled stylesheet changes **61 existing custom properties**, adds **5** and removes **6**. Of the 61 changes, 56 change a resolved root/sidebar value and five change only a declaration or a component scope. These counts compare declarations and resolved raw values, before the native compatibility slot described below. A property appears once in the count even when several contexts change. Across compiled and source-only declarations, the inventory contains **62 changed**, **8 added** and **9 removed** token names. The table lists each changed context, including the sidebar, so inherited and contrast-derived changes remain visible. Colors are rounded sRGB hex; the generated Swift also records Display P3 and extended-gamut values. Expressions which change without changing their resolved color still appear.

T3 source citations below refer to `apps/web/src/index.css` at `v0.1.4-nightly.20261028.3814`: sidebar icon mix 106-110, font stack 170-175, composer shadow 196-200, color utilities 239-279, light palette 1113-1184, dark palette 1187-1228, sidebar overrides 1234-1278, diff icons 1281-1305, diff text 2277-2282. `apps/web/index.html:399-407` carries the same sans stack on the initial boot page.

| Token | Context | 3669 | 3814 |
|---|---|---|---|
| `--app-chrome-background` | Dark, Sidebar dark | `#0a0a0a` | `#000000` |
| `--background` | Dark | `#0a0a0a` | `#000000` |
| `--border` | Dark | `#ffffff0f` | `#ffffff14` |
| `--card-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--code-background` | Dark, Sidebar dark | `#111111` | `#101010` |
| `--code-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--color-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--color-foreground` | Dark, Sidebar dark | `color-mix(in oklab, color-mix(in oklab, oklch(97% 0 none) 100%, oklch(14.5% 0 none)), white 0%)` | `color-mix(in oklab, color-mix(in oklab, oklch(97% 0 none) 100%, #000), white 0%)` |
| `--color-muted-foreground` | Dark, Sidebar dark | `#818181` | `#a1a1a1` |
| `--contrast-border` | Light, Sidebar light | `color-mix(in srgb, color-mix(in srgb, oklch(92% .004 286.32) 100%, transparent), oklch(27.4% .006 286.033) 0%)` | `color-mix(in srgb, color-mix(in srgb, oklch(92% .004 286.32) 100%, transparent), oklch(21% .006 285.885) 0%)` |
| `--contrast-border` | Dark | `#ffffff0f` | `#ffffff14` |
| `--contrast-card-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--contrast-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--contrast-foreground` | Dark | `color-mix(in oklab, color-mix(in oklab, oklch(97% 0 none) 100%, oklch(14.5% 0 none)), white 0%)` | `color-mix(in oklab, color-mix(in oklab, oklch(97% 0 none) 100%, #000), white 0%)` |
| `--contrast-icon-muted` | Dark, Sidebar dark | `#818181` | `#a1a1a1` |
| `--contrast-input` | Light, Sidebar light | `color-mix(in srgb, color-mix(in srgb, oklch(87.1% .006 286.286) 100%, transparent), oklch(27.4% .006 286.033) 0%)` | `color-mix(in srgb, color-mix(in srgb, oklch(87.1% .006 286.286) 100%, transparent), oklch(21% .006 285.885) 0%)` |
| `--contrast-input` | Dark | `#ffffff14` | `#ffffff1c` |
| `--contrast-message-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--contrast-message-foreground` | Dark, Sidebar dark | `color-mix(in oklab, color-mix(in oklab, oklch(97% 0 none) 100%, color-mix(in oklab, #fff 4%, transparent)), white 0%)` | `color-mix(in oklab, color-mix(in oklab, oklch(97% 0 none) 100%, color-mix(in srgb, oklch(14.5% 0 none) 92%, #fff)), white 0%)` |
| `--contrast-muted-foreground` | Dark | `#818181` | `#a1a1a1` |
| `--contrast-placeholder` | Dark, Sidebar dark | `#818181` | `#a1a1a1` |
| `--contrast-popover-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--contrast-secondary-label` | Dark | `#818181` | `#a1a1a1` |
| `--contrast-secondary-label` | Sidebar dark | `#818181` | `#8f8f8f` |
| `--contrast-sidebar-border` | Light, Sidebar light | `color-mix(in srgb, color-mix(in srgb, oklch(92% .004 286.32) 100%, transparent), oklch(27.4% .006 286.033) 0%)` | `color-mix(in srgb, color-mix(in srgb, oklch(92% .004 286.32) 100%, transparent), oklch(21% .006 285.885) 0%)` |
| `--contrast-sidebar-border` | Dark | `#ffffff0f` | `#ffffff14` |
| `--contrast-sidebar-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--contrast-sidebar-muted-foreground` | Dark | `#818181` | `#a1a1a1` |
| `--contrast-toolbar-border` | Light, Sidebar light | `color-mix(in srgb, color-mix(in srgb, oklch(92% .004 286.32) 100%, transparent), oklch(27.4% .006 286.033) 0%)` | `color-mix(in srgb, color-mix(in srgb, oklch(92% .004 286.32) 100%, transparent), oklch(21% .006 285.885) 0%)` |
| `--contrast-toolbar-border` | Dark, Sidebar dark | `#ffffff0f` | `#ffffff14` |
| `--contrast-toolbar-control-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--contrast-toolbar-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--contrast-toolbar-foreground` | Dark, Sidebar dark | `color-mix(in oklab, color-mix(in oklab, oklch(97% 0 none) 100%, oklch(14.5% 0 none)), white 0%)` | `color-mix(in oklab, color-mix(in oklab, oklch(97% 0 none) 100%, #000), white 0%)` |
| `--default-font-family` | Light, Dark, Sidebar light, Sidebar dark | `-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif` | `-apple-system, BlinkMacSystemFont, "Inter Variable", "Segoe UI", system-ui, sans-serif` |
| `--diff-addition-foreground` | Light, Sidebar light | `#009966` | `#007a55` |
| `--diff-deletion-foreground` | Light, Sidebar light | `#e7000b` | `#c10007` |
| `--diffs-header-font-family` | Light, Dark, Sidebar light, Sidebar dark | `-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif` | `-apple-system, BlinkMacSystemFont, "Inter Variable", "Segoe UI", system-ui, sans-serif` |
| `--font-sans` | Light, Dark, Sidebar light, Sidebar dark | `-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif` | `-apple-system, BlinkMacSystemFont, "Inter Variable", "Segoe UI", system-ui, sans-serif` |
| `--foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--guest-surface` | Light, Sidebar light | `#f1d8f6` | `#ead0ef` |
| `--guest-surface` | Dark, Sidebar dark | `#e754fc2c` | `#391f3d` |
| `--icon-muted` | Dark, Sidebar dark | `#818181` | `#a1a1a1` |
| `--input` | Dark | `#ffffff14` | `#ffffff1c` |
| `--message-action-hover` | Dark, Sidebar dark | `#3061da` | `#2f60d9` |
| `--message-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--message-surface` | Light, Sidebar light | `#f4f4f5` | `#ebebed` |
| `--message-surface` | Dark, Sidebar dark | `#ffffff0a` | `#1e1e1e` |
| `--muted-foreground` | Dark | `#818181` | `#a1a1a1` |
| `--placeholder` | Dark, Sidebar dark | `#818181` | `#a1a1a1` |
| `--popover-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--radius` | Light, Dark, Sidebar light, Sidebar dark | `.625rem` | `.5rem` |
| `--radius-2xl` | Light, Dark, Sidebar light, Sidebar dark | `calc(.625rem + 8px)` | `calc(.5rem + 8px)` |
| `--radius-lg` | Light, Dark, Sidebar light, Sidebar dark | `.625rem` | `.5rem` |
| `--radius-md` | Light, Dark, Sidebar light, Sidebar dark | `calc(.625rem - 2px)` | `calc(.5rem - 2px)` |
| `--radius-sm` | Light, Dark, Sidebar light, Sidebar dark | `calc(.625rem - 4px)` | `calc(.5rem - 4px)` |
| `--radius-xl` | Light, Dark, Sidebar light, Sidebar dark | `calc(.625rem + 4px)` | `calc(.5rem + 4px)` |
| `--secondary-label` | Dark | `#818181` | `#a1a1a1` |
| `--secondary-label` | Sidebar dark | `#818181` | `#8f8f8f` |
| `--sidebar-border` | Dark | `#ffffff0f` | `#ffffff14` |
| `--sidebar-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--sidebar-icon-color` | Light, Sidebar light | `#a8a8ae` | `#85858e` |
| `--sidebar-icon-color` | Dark, Sidebar dark | `#545454` | `#8b8b8b` |
| `--sidebar-muted-foreground` | Dark | `#818181` | `#a1a1a1` |
| `--terminal-background` | Dark, Sidebar dark | `#0a0a0a` | `#000000` |
| `--terminal-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--toolbar-background` | Dark, Sidebar dark | `#0a0a0a` | `#000000` |
| `--toolbar-border` | Dark, Sidebar dark | `#ffffff0f` | `#ffffff14` |
| `--toolbar-control-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |
| `--toolbar-foreground` | Light, Sidebar light | `#27272a` | `#18181b` |

## Added tokens

| Token | Light | Dark | Sidebar light | Sidebar dark |
|---|---|---|---|---|
| `--color-neutral-400` | `#a1a1a1` | `#a1a1a1` | `#a1a1a1` | `#a1a1a1` |
| `--context-chip-ink` | `var(--context-chip-accent); var(--context-chip-message,var(--context-chip-accent))` | `var(--context-chip-accent); var(--context-chip-message,var(--context-chip-accent))` | `var(--context-chip-accent); var(--context-chip-message,var(--context-chip-accent))` | `var(--context-chip-accent); var(--context-chip-message,var(--context-chip-accent))` |
| `--diff-added-icon` | `absent` | `#00d492` | `absent` | `#00d492` |
| `--diff-modified-icon` | `#425cb1` | `#51a2ffa6` | `#425cb1` | `#51a2ffa6` |
| `--document-icon-stroke` | `var(--context-chip-ink)` | `var(--context-chip-ink)` | `var(--context-chip-ink)` | `var(--context-chip-ink)` |

## Removed tokens

| Token | Light | Dark | Sidebar light | Sidebar dark |
|---|---|---|---|---|
| `--color-neutral-500` | `#737373` | `#737373` | `#737373` | `#737373` |
| `--context-chip-border` | `color-mix(in oklab,var(--context-chip-accent) 34%,var(--contrast-border)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 34%,var(--contrast-border)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 34%,var(--contrast-border)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 34%,var(--contrast-border)); var(--context-chip-accent)` |
| `--context-chip-border-hover` | `color-mix(in oklab,var(--context-chip-accent) 48%,var(--contrast-border)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 48%,var(--contrast-border)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 48%,var(--contrast-border)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 48%,var(--contrast-border)); var(--context-chip-accent)` |
| `--context-chip-foreground` | `color-mix(in oklab,var(--context-chip-accent) 22%,var(--contrast-foreground)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 22%,var(--contrast-foreground)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 22%,var(--contrast-foreground)); var(--context-chip-accent)` | `color-mix(in oklab,var(--context-chip-accent) 22%,var(--contrast-foreground)); var(--context-chip-accent)` |
| `--ease-in` | `cubic-bezier(.4, 0, 1, 1)` | `cubic-bezier(.4, 0, 1, 1)` | `cubic-bezier(.4, 0, 1, 1)` | `cubic-bezier(.4, 0, 1, 1)` |
| `--update-surface` | `#1b4ed81f` | `#346bf12e` | `#1b4ed81f` | `#346bf12e` |


## Declaration changes with no resolved root difference

These values occur in component scopes or preserve the rendered root color. The context-chip variables require the chip's runtime accent variables, so their declaration values appear above instead of a color swatch. All listed chip branches apply in both light and dark. The root/sidebar extractor cannot resolve these component-only variables.

| Token | Context | 3669 declaration(s) | 3814 declaration(s) |
|---|---|---|---|
| `--card` | Both modes, scoped overrides; dark root for the neutral-950 mixes | `#000`; `color-mix(in srgb, var(--background) 97%, var(--color-white))`; `var(--app-theme-surface)`; `var(--background)`; `var(--color-white)` | `#000`; `#111`; `color-mix(in srgb, var(--color-neutral-950) 97%, var(--color-white))`; `var(--app-theme-surface)`; `var(--color-white)` |
| `--popover` | Both modes, scoped overrides; dark root for the neutral-950 mixes | `color-mix(in srgb, var(--background) 97%, var(--color-white))`; `var(--app-theme-surface-overlay)`; `var(--background)`; `var(--color-white)` | `#111`; `color-mix(in srgb, var(--color-neutral-950) 97%, var(--color-white))`; `var(--app-theme-surface-overlay)`; `var(--color-white)` |
| `--surface-raised` | Both modes, scoped overrides; dark root for the neutral-950 mixes | `color-mix(in srgb, var(--background) 97%, var(--color-white))`; `color-mix(in srgb, var(--card) 20%, transparent)`; `var(--app-theme-surface-raised)`; `var(--background)`; `var(--card)` | `#111`; `color-mix(in srgb, var(--card) 20%, transparent)`; `color-mix(in srgb, var(--color-neutral-950) 97%, var(--color-white))`; `var(--app-theme-surface-raised)`; `var(--card)` |
| `--chat-composer-attachment-overlap` | Both modes, scoped overrides; dark root for the neutral-950 mixes | `0px`; `calc(1rem + 1px)` | `calc(1rem + 1px)` |
| `--context-chip-accent` | Both modes, scoped overrides; dark root for the neutral-950 mixes | `oklch(62% .02 259)`; `oklch(62% .11 215)`; `oklch(62% .12 190)`; `oklch(62% .134 163)`; `oklch(62% .134 70)`; `oklch(62% .136 237)`; `oklch(62% .16 16)`; `oklch(62% .16 259)`; `oklch(62% .16 277)`; `oklch(62% .16 292)`; `oklch(62% .16 322)`; `oklch(62% .16 48)` | `currentColor`; `var(--context-chip-citation)`; `var(--context-chip-doc-epub)`; `var(--context-chip-doc-pdf)`; `var(--context-chip-doc-slides)`; `var(--context-chip-doc-spreadsheet)`; `var(--context-chip-doc-word)`; `var(--context-chip-element)`; `var(--context-chip-environment)`; `var(--context-chip-file)`; `var(--context-chip-image)`; `var(--context-chip-invalid,var(--destructive-foreground))`; `var(--context-chip-mention)`; `var(--context-chip-pr-closed)`; `var(--context-chip-pr-draft)`; `var(--context-chip-pr-merged)`; `var(--context-chip-pr-open)`; `var(--context-chip-preview-annotation)`; `var(--context-chip-pull-request)`; `var(--context-chip-review-comment)`; `var(--context-chip-skill)`; `var(--context-chip-terminal)`; `var(--context-chip-thread)`; `var(--context-chip-video)` |

## Source tokens absent from the compiled declarations

Tailwind inlines or drops unused theme declarations. These source changes therefore need a separate inventory and do not enter the 61/5/6 compiled-property counts above.

| Token | Context | 3669 | 3814 |
|---|---|---|---|
| `--shadow-composer` | Light and dark declaration | `0 12px 28px -18px rgb(0 0 0 / 40%)` | `0 1px 2px rgb(0 0 0 / 5%)` |
| `--animate-stash-pulse-row` | Both, added | absent | `stash-pulse-row 1400ms` |
| `--animate-stash-pulse-row-alt` | Both, added | absent | `stash-pulse-row-alt 1400ms` |
| `--animate-stash-pulse-count` | Both, added | absent | `stash-pulse-count 1400ms step-start` |
| `--color-update-surface` | Both, removed | `var(--update-surface)` | absent |
| `--color-surface-raised` | Both, removed | `var(--surface-raised)` | absent |
| `--color-code-foreground` | Both, removed | `var(--code-foreground)` | absent |

`--surface-raised` and `--code-foreground` themselves remain defined. Only their Tailwind color utility aliases disappear. The dark raised surfaces now refer directly to neutral-950, preserving their existing tone while the canvas becomes black. `--shadow-composer-dark` remains unchanged in source and is also absent from compiled declarations.

## Extraction and native compatibility

- `scripts/extract-tokens --version v0.1.4-nightly.20261028.3814` regenerates `Tokens.generated.swift`, `ThemeExpressions.generated.swift`, `docs/design-tokens.md` and `fixtures/theme/theme-runtime-chromium.json`. The explicit version labels design artifacts without changing the runtime pin.
- `T3_DESIGN_VERSION=v0.1.4-nightly.20261028.3814 python3 scripts/gen-theme-palettes.py <3814 source directory>` regenerates `ThemePalettes.generated.swift`. `themePalettes.ts` has no source changes between 3669 and 3814; the checked-in generated file previously dated from 2861.
- The extractor finds the radius (0.625rem to 0.5rem), black canvas, neutral-950 raised surfaces, message surfaces, alpha borders and inputs, sidebar secondary label, sidebar icon mix and both diff icon roles without manual copies. `--diff-added-icon` exists only in dark mode; the light native slot is transparent, matching CSS's absent-value fallback. Blue-orange diff suppresses this slot and dims modified icons like T3.
- `--update-surface` remains a native compatibility slot with a transparent T3 default. It is absent in the shipped 3814 CSS. CandyWrapper's own themes retain their previous value through their frozen tables. The theme-file role still exists in T3's shared contracts.
- The composer's shadow is hard-coded in `Features/Composer/ComposerView.swift:323-330`, rather than a matching shared token. Updating it belongs to the component port; this task does not change components. The absent stash declarations likewise belong to the stash component's motion port.
- The generated sans stack adds "Inter Variable" after `-apple-system` and `BlinkMacSystemFont`. T3 imports the webfont in `apps/web/src/main.tsx:4`. A Chromium `CSS.getPlatformFontsForNode` probe on this Mac returned family `.SF NS`, PostScript name `.SFNS-Regular`, `isCustomFont: false`, for all 23 probe glyphs. The first available font remains the Apple system face. Native `DSFont` already uses `NSFont.systemFont`, so no font implementation change is needed.

## CandyWrapper theme baseline

`fixtures/theme/candy-3669-baseline.json` records all 117 palette roles from base commit `979c85e5a6a0e47429af04291880d05bd3a69792` before regenerating the tokens. `CandyThemeBaselineTests` compares every sRGB and Display P3 component exactly for Redesign (`candywrapper-dither`) and Glass (`candywrapper-glass`), in all four contexts, at contrast 80/100/120 and opacity 10/80/100. New 3814-only slots have no pre-change value to compare.

`CandyTheme3669.swift` freezes the previous default theme colors, stock token colors, and standard/themed expressions. The runtime selects these only for Redesign or Glass, before the existing frost and readability transforms. The shared built-in themes and T3 defaults use the 3814 expressions. This also preserves custom Redesign accents and contrast/opacity behavior instead of recording only one final palette.

## Validation

- `swift build` in `Packages/CandyKit`: passed.
- `scripts/test --fast`: 2,207 Swift Testing tests and 19 XCTest tests passed. All 67,392 recorded color components for Redesign and Glass match exactly. The shared-palette test now checks the supplied editor roles directly, because 3814's shared defaults retain zinc-800 text and a neutral-950 canvas while its unthemed CSS uses zinc-900 and black. The Glass integration test compares readability adjustments with Glass's own retained colors.
- `scripts/build-test-app tokens-3814`: passed. Reviewed the isolated app's native window snapshots in light and dark against the existing 47391 sandbox, under `~/CandyWrapper-research/sandbox/tokens-3814-review/`. An existing Keychain dialog left Safari frontmost and prevented interactive screen checks; the dialog stayed untouched. Both snapshot launches quit, the screen lock was released and `/tmp/cw-dd-tokens-3814` was deleted.
- `scripts/test --filter Fidelity`: completed all 137 tests (71 Features, 66 DesignSystem). 95 test methods failed across 54 suites, with 968 assertions: 924 case assertions cover 904 distinct cases, and 44 other assertions include suite means and one blur comparison. See [every failing case and diff, grouped by suite](nightly-3814-fidelity.md). The vImage/Core Image comparison on the default dark toggle gallery reports a worst-channel difference of 3/255 against its unchanged 2/255 ceiling.

`scripts/extract-tokens --version v0.1.4-nightly.20261028.3814 --load <resolved dump>` reproduces all four generated artifacts byte for byte. Reviewed the diff and verified that `T3_VERSION`, `ServerVersionSkewLogic`, component sources, references and fidelity thresholds remain unchanged.

Default-theme fidelity failures are expected because references and components still target the older design. The black canvas alone crosses the 8/255 pixel tolerance against the previous neutral-950 background. References, ceilings and components stay unchanged.

## 3814 to 3824

The port follows 3824 where 3824 changed a design piece. 3824's stylesheet (`main-Bph4ghsZ.css`) changes no color, radius, shadow or type token. Two composer lengths are gone with the old composer seam (#25869): `--spacing-composer-seam` (`calc(.25rem * 4 - 1px)`) and `--chat-composer-context-extension`. The chat table rules changed with #26449 (no `min-width: max-content`, cells wrap up to 24rem).
